import AppKit
import SwiftUI

/// 앱 조립과 생명주기만 담당한다. 화면 상태와 동작은 AppModel이, 메뉴바 아이콘은
/// TreeAnimator가 맡는다. 종전에는 NSMenu 구축·갱신·알럿까지 여기서 다 했는데,
/// 패널 전환 후엔 "감시기 → 모델 → 뷰" 흐름만 연결한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var animator: TreeAnimator!
    private var statsTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenSleeping = false
    private var sessionInactive = false

    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let memoryPressureMonitor = MemoryPressureMonitor()
    private let swapMonitor = SwapMonitor()
    private let diskMonitor = DiskMonitor()

    private let keepAwake = KeepAwake()
    private let clipboardWatcher = ClipboardWatcher()
    private let screenshotWatcher = ScreenshotWatcher()
    private let usageProvider = UsageProvider()
    private let historyPanel = HistoryPanelController()

    private lazy var model = AppModel(keepAwake: keepAwake)
    private lazy var mainPanel = MainPanelController(model: model)
    private var hotKey: HotKey?

    private var cpuHistory: [Double] = []
    private var memHistory: [Double] = []
    private let historyCapacity = 120  // 0.5초 간격 x 120 = 최근 1분
    private var latestSwap: SwapUsage?
    private var latestDisk: DiskUsage?
    private var lastSwapSample = Date.distantPast
    private var lastDiskSample = Date.distantPast
    private var isMainPanelVisible = false

    private let swapSampleInterval: TimeInterval = 2
    private let diskSampleInterval: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        logBuildIdentity()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        animator = TreeAnimator(button: button)
        mainPanel.anchorButton = button
        historyPanel.anchorButton = button

        wireModel()
        refreshKeepAwakeState()

        // 좌클릭 = 패널 열기/닫기, 우클릭(또는 control-클릭) = 잠들지 않기 토글.
        // 그래서 statusItem.menu 를 고정하지 않고 버튼 액션으로 직접 처리한다.
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        clipboardWatcher.start()
        // both 모드에서만 파일 감시가 필요하다 (clipboardOnly는 macOS가 직접 처리).
        if ScreenshotMode.current == .both { screenshotWatcher.start() }
        usageProvider.start()
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

        memoryPressureMonitor.start()
        _ = cpuMonitor.sample()  // 첫 샘플은 델타 기준점만 잡음
        // 0.5초마다 샘플링 — 나무 흔들림이 CPU 변화를 촘촘하고 민감하게 따라가도록.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSystemStats()
                self?.clipboardWatcher.poll()
            }
        }
        // CPU/클립보드처럼 비슷한 주기의 타이머가 한꺼번에 깨어날 수 있게 여유를 준다.
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainPanel.close()
        historyPanel.close()
        statsTimer?.invalidate()
        statsTimer = nil
        clipboardWatcher.stop()
        screenshotWatcher.stop()
        usageProvider.stop()
        memoryPressureMonitor.stop()
        keepAwake.onChange = nil
        keepAwake.disable()
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

        mainPanel.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.isMainPanelVisible = visible
            if visible {
                // 열기 직전에 최신 스냅샷을 한 번 밀어 넣는다. 디스크는 최근 15초 안에
                // 읽었다면 캐시를 써서 빠른 재클릭이 비싼 조회를 반복하지 않게 한다.
                self.refreshSystemStats(forcePublish: true, diskMaxAge: 15)
                self.usageProvider.refreshIfStale(maxAge: 300)
            }
        }

        // 사용량 조회 결과가 바뀔 때마다 모델로 밀어 넣는다 (→ 패널 자동 갱신)
        model.updateUsage(usageProvider.usages, statusText: usageProvider.statusText)
        usageProvider.onUpdate = { [weak self] in
            guard let self else { return }
            self.model.updateUsage(
                self.usageProvider.usages, statusText: self.usageProvider.statusText)
        }

        keepAwake.onChange = { [weak self] in self?.refreshKeepAwakeState() }
    }

    /// KeepAwake 상태가 바지면 아이콘 점과 모델(→패널 표시)을 함께 갱신한다.
    private func refreshKeepAwakeState() {
        animator?.setAwake(keepAwake.isActive)
        model.syncAwake(from: keepAwake)
    }

    @objc private func handleShowHistoryPanel() {
        historyPanel.show()
    }

    /// 스크립트용 — 패널을 열고 잠시 뒤 자동으로 닫는다 (종전 메뉴 취소 동작과 동일).
    @objc private func handleShowMenu() {
        mainPanel.show()
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.mainPanel.close() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleToggleAwake() {
        keepAwake.toggle()
    }

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

    private func refreshSystemStats(
        forcePublish: Bool = false,
        diskMaxAge: TimeInterval? = nil
    ) {
        let cpu = cpuMonitor.sample()
        animator.update(cpuUsage: cpu)
        let mem = memoryMonitor.sample()

        cpuHistory.append(cpu)
        if cpuHistory.count > historyCapacity { cpuHistory.removeFirst() }
        memHistory.append(mem.usedFraction)
        if memHistory.count > historyCapacity { memHistory.removeFirst() }

        // 평소엔 흑백 나무 그대로, CPU/RAM 중 하나라도 경고 수준이면 그때만 색을 입힌다.
        // RAM은 사용량 %가 아니라 커널의 실제 메모리 압박 신호를 기준으로 삼는다 —
        // macOS가 남는 RAM을 파일 캐시로 항상 꽉 채우는 게 정상이라 %만 보면 늘 빨간색이 된다.
        let level = SystemThresholds.worse(
            SystemThresholds.cpuLevel(cpu), memoryPressureMonitor.level)
        animator.setWarningLevel(level)

        let now = Date()
        let needsPanelStats = isMainPanelVisible || forcePublish
        if needsPanelStats {
            if latestSwap == nil || now.timeIntervalSince(lastSwapSample) >= swapSampleInterval {
                latestSwap = swapMonitor.sample()
                lastSwapSample = now
            }

            let allowedDiskAge = diskMaxAge ?? diskSampleInterval
            if latestDisk == nil || now.timeIntervalSince(lastDiskSample) >= allowedDiskAge {
                latestDisk = diskMonitor.sample()
                lastDiskSample = now
            }
        }

        guard needsPanelStats else { return }
        publishSystemSnapshot(cpu: cpu, memory: mem)
    }

    private func publishSystemSnapshot(cpu: Double, memory: MemoryUsage) {
        let swap = latestSwap
        let disk = latestDisk
        model.updateSystem(
            SystemSnapshot(
                cpuFraction: cpu,
                cpuHistory: cpuHistory,
                memHistory: memHistory,
                memLevel: memoryPressureMonitor.level,
                memUsedGB: memory.usedGB,
                memTotalGB: memory.totalGB,
                memCompressedGB: memory.compressedGB,
                swapUsedGB: swap?.usedGB ?? 0,
                diskFraction: disk?.usedFraction ?? 0,
                diskUsedGB: disk?.usedGB ?? 0,
                diskTotalGB: disk?.totalGB ?? 0,
                diskPurgeableGB: disk?.purgeableGB ?? 0))
    }

    /// 메뉴바가 보이지 않는 화면 잠자기/잠금 동안 아이콘 애니메이션만 멈춘다.
    /// 클립보드 감시는 백그라운드 복사를 놓치지 않도록 계속 유지한다.
    private func observeWorkspacePowerState() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenSleeping = true
                    self?.updateAnimationSuspension()
                }
            })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenSleeping = false
                    self?.updateAnimationSuspension()
                }
            })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionInactive = true
                    self?.updateAnimationSuspension()
                }
            })
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionInactive = false
                    self?.updateAnimationSuspension()
                }
            })
    }

    private func updateAnimationSuspension() {
        animator?.setSuspended(screenSleeping || sessionInactive)
    }

    private func logBuildIdentity() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let revision = info?["ShakeTreeGitRevision"] as? String ?? "unknown"
        NSLog("ShakeTree 시작: version=\(version) build=\(build) revision=\(revision)")
    }
}
