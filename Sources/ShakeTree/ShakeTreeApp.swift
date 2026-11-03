import AppKit
import SwiftUI

/// 앱 조립과 생명주기만 담당한다. 화면 상태와 동작은 AppModel이, 메뉴바 아이콘은
/// TreeAnimator가 맡는다. 종전에는 NSMenu 구축·갱신·알럿까지 여기서 다 했는데,
/// 패널 전환 후엔 "감시기 → 모델 → 뷰" 흐름만 연결한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var animator: TreeAnimator!
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenSleeping = false
    private var sessionInactive = false

    private let metrics = SystemMetricsService()
    private let powerMonitor = PowerMonitor()
    private var usageEnabled: Bool?
    private var usageWasVisible = false
    private var activeDetail: DetailPage?
    private var detailVisible = false
    private let settingsWindow = UtilityWindowController()
    private let detailWindow = UtilityWindowController()

    private let keepAwake = KeepAwake()
    private let lidAwake = LidAwakeController()
    private let clipboardWatcher = ClipboardWatcher()
    private let screenshotWatcher = ScreenshotWatcher()
    private let usageProvider = UsageProvider()
    private let historyPanel = HistoryPanelController()

    private lazy var model = AppModel(keepAwake: keepAwake)
    private lazy var mainPanel = MainPanelController(model: model)
    private var hotKey: HotKey?

    private var isMainPanelVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logBuildIdentity()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        animator = TreeAnimator(button: button)
        mainPanel.anchorButton = button
        historyPanel.anchorButton = button

        wireModel()
        powerMonitor.start()
        keepAwake.configure(power: powerMonitor.snapshot, settings: model.resources)
        keepAwake.restoreAfterInterruption()
        refreshKeepAwakeState()
        if !keepAwake.isActive { lidAwake.recoverIfNeeded() }

        // 좌클릭 = 패널 열기/닫기, 우클릭(또는 control-클릭) = 잠들지 않기 토글.
        // 그래서 statusItem.menu 를 고정하지 않고 버튼 액션으로 직접 처리한다.
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // both 모드에서만 파일 감시가 필요하다 (clipboardOnly는 macOS가 직접 처리).
        if ScreenshotMode.current == .both { screenshotWatcher.start() }
        hotKey = HotKey { [historyPanel] in historyPanel.toggle() }
        observeWorkspacePowerState()

        // accessory 앱은 분산 알림이 기본 보류되므로 즉시 전달로 등록 (스크립팅/테스트용)
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self, selector: #selector(handleShowHistoryPanel),
            name: Notification.Name("dev.yubyeongju.shaketree.show-panel"), object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(
            self, selector: #selector(handleShowMenu),
            name: Notification.Name("dev.yubyeongju.shaketree.show-menu"), object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(
            self, selector: #selector(handleToggleAwake),
            name: Notification.Name("dev.yubyeongju.shaketree.toggle-awake"), object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(handleRestoreAwake(_:)),
            name: Notification.Name("dev.yubyeongju.shaketree.restore-awake"), object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(handleQuit),
            name: Notification.Name("dev.yubyeongju.shaketree.quit"), object: nil,
            suspensionBehavior: .deliverImmediately)

        configureResources()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainPanel.close()
        settingsWindow.close()
        detailWindow.close()
        historyPanel.close()
        metrics.stop()
        powerMonitor.stop()
        clipboardWatcher.stop()
        screenshotWatcher.stop()
        usageProvider.stop()
        keepAwake.onChange = nil
        keepAwake.disable()
        lidAwake.onChange = nil
        lidAwake.onExpired = nil
        lidAwake.configure(enabled: false, endsAt: nil)
        animator?.stop()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspaceCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// 모델의 주입 지점에 실제 서비스를 연결한다.
    private func wireModel() {
        model.startScreenshotWatcher = { [screenshotWatcher] start in
            start ? screenshotWatcher.start() : screenshotWatcher.stop()
        }
        model.showHistoryPanel = { [historyPanel] in historyPanel.show() }
        model.refreshUsage = { [weak self] in self?.usageProvider.refresh() }
        model.cancelUsageRefresh = { [weak self] in self?.usageProvider.cancelRefresh() }
        model.refreshUsageProvider = { [weak self] provider in self?.usageProvider.refresh(providers: [provider]) }

        mainPanel.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.isMainPanelVisible = visible
            self.configureResources()
        }

        // 사용량 조회 결과가 바뀔 때마다 모델로 밀어 넣는다 (→ 패널 자동 갱신)
        model.updateUsage(usageProvider.usages, statusText: usageProvider.statusText)
        usageProvider.onUpdate = { [weak self] in
            guard let self else { return }
            self.model.updateUsage(
                self.usageProvider.usages, statusText: self.usageProvider.statusText,
                isRefreshing: self.usageProvider.isRefreshing,
                progress: self.usageProvider.progress)
        }

        keepAwake.onChange = { [weak self] in self?.refreshKeepAwakeState() }
        lidAwake.onChange = { [weak self] in self?.refreshKeepAwakeState() }
        lidAwake.onExpired = { [weak self] in self?.keepAwake.reconcileAfterWake() }
        metrics.onSnapshot = { [weak self] in self?.model.updateSystem($0) }
        metrics.onIcon = { [weak self] cpu, level in
            self?.animator.update(cpuUsage: cpu)
            self?.animator.setWarningLevel(level)
        }
        powerMonitor.onChange = { [weak self] power in
            guard let self else { return }
            self.model.updatePower(power)
            self.keepAwake.configure(power: power, settings: self.model.resources)
            self.lidAwake.recheckAfterPowerChange()
            self.configureResources()
        }
        model.onResourcesChange = { [weak self] in
            guard let self else { return }
            self.keepAwake.configure(power: self.powerMonitor.snapshot, settings: self.model.resources)
            self.refreshKeepAwakeState()
            self.configureResources()
        }
        model.showSettingsWindow = { [weak self] page in
            guard let self else { return }
            self.mainPanel.close()
            self.settingsWindow.show(title: "Shake Tree 설정", size: NSSize(width: 480, height: 420),
                                     content: AnyView(SettingsWindowView(model: self.model, page: page)))
        }
        model.showDetailWindow = { [weak self] page in
            guard let self else { return }
            self.activeDetail = page
            self.detailVisible = true
            self.configureResources()
            self.mainPanel.close()
            let title = page.provider.flatMap { id in self.model.usage.usages.first { $0.provider == id }?.displayName } ?? "시스템"
            self.detailWindow.show(title: "\(title) · Shake Tree", size: NSSize(width: 400, height: 300),
                                   content: AnyView(DetailWindowView(model: self.model, page: page)))
        }
        detailWindow.onClose = { [weak self] in
            self?.activeDetail = nil
            self?.detailVisible = false
            self?.configureResources()
        }
        detailWindow.onVisibilityChange = { [weak self] visible in
            self?.detailVisible = visible
            self?.configureResources()
        }
    }

    /// KeepAwake 상태가 바지면 아이콘 점과 모델(→패널 표시)을 함께 갱신한다.
    private func refreshKeepAwakeState() {
        animator?.setAwake(keepAwake.isActive)
        lidAwake.configure(enabled: keepAwake.isActive && model.resources.lidAwakeEnabled,
                           endsAt: keepAwake.endsAt)
        model.syncAwake(from: keepAwake, lidStatus: lidAwake.status)
    }

    @objc private func handleShowHistoryPanel() {
        historyPanel.show()
    }

    /// 스크립트용 — 사용자가 열었을 때와 같은 패널을 유지해 실제 표시를 검수한다.
    @objc private func handleShowMenu() {
        mainPanel.show()
    }

    @objc private func handleToggleAwake() {
        keepAwake.toggle()
    }

    @objc private func handleRestoreAwake(_ notification: Notification) {
        guard let remaining = notification.userInfo?["remainingSeconds"] as? Double,
              remaining.isFinite, remaining != 0 else { return }
        keepAwake.enable(duration: remaining < 0 ? nil : min(remaining, 86400))
    }
    @objc private func handleQuit() { NSApp.terminate(nil) }

    /// 좌클릭=패널, 우클릭/control-클릭=잠들지 않기 토글
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight =
            event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            keepAwake.toggle()
        } else {
            mainPanel.toggle()
        }
    }

    private func configureResources() {
        let suspended = screenSleeping || sessionInactive
        let settings = model.resources
        let systemVisible = isMainPanelVisible || (detailVisible && activeDetail?.isSystem == true)
        let usageVisible = (isMainPanelVisible || (detailVisible && activeDetail?.provider != nil)) && !suspended && settings.usageEnabled
        let becameVisible = usageVisible && !usageWasVisible
        usageWasVisible = usageVisible
        let policy = ResourcePolicy(settings: settings, power: powerMonitor.snapshot,
                                    visible: systemVisible, suspended: suspended)
        metrics.configure(policy: policy, visible: systemVisible)
        clipboardWatcher.configurePolling(enabled: settings.clipboardEnabled, suspended: suspended)
        animator?.configure(enabled: policy.animationEnabled, frameRate: policy.frameRate)
        if !settings.systemEnabled { animator?.setWarningLevel(.normal) }
        // Stop scheduling while hidden, but let one already-started bounded round finish
        // and populate the cache. Locking the screen or disabling the module still cancels.
        usageProvider.setPanelVisible(usageVisible, cancelInFlight: suspended || !settings.usageEnabled)
        if usageEnabled != settings.usageEnabled {
            usageEnabled = settings.usageEnabled
            settings.usageEnabled ? usageProvider.start() : usageProvider.stop()
        }
        if becameVisible {
            usageProvider.refreshIfStale(maxAge: 300, providers: isMainPanelVisible ? nil : activeDetail?.provider.map { [$0] })
        }
    }

    /// Screen sleep/lock stops sampling, animation and clipboard wakeups.
    /// The clipboard's last changeCount survives so the latest copy is read on wake.
    private func observeWorkspacePowerState() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAwake.reconcileAfterWake() }
        })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenSleeping = true
                    self?.configureResources()
                }
            })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenSleeping = false
                    self?.configureResources()
                }
            })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionInactive = true
                    self?.configureResources()
                }
            })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionInactive = false
                    self?.configureResources()
                }
            })
    }

    private func logBuildIdentity() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let revision = info?["ShakeTreeGitRevision"] as? String ?? "unknown"
        NSLog("ShakeTree 시작: version=\(version) build=\(build) revision=\(revision)")
    }
}
