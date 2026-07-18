import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var animator: TreeAnimator!
    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private var statsTimer: Timer?
    private var systemStatusItem: NSMenuItem!
    private var systemStatusHost: NSHostingView<SystemStatusView>!
    private var cpuHistory: [Double] = []
    private var memHistory: [Double] = []
    private let historyCapacity = 120  // 0.5초 간격 x 120 = 최근 1분

    private let clipboardWatcher = ClipboardWatcher()
    private let historyPanel = HistoryPanelController()
    private var hotKey: HotKey?
    private let screenshotWatcher = ScreenshotWatcher()
    private var screenshotBothItem: NSMenuItem!
    private var screenshotClipItem: NSMenuItem!
    private let usageProvider = UsageProvider()
    private let keepAwake = KeepAwake()
    private var keepAwakeItem: NSMenuItem!
    private var keepAwakeOptions: [(title: String, minutes: Int?)] = []
    private var menu: NSMenu!
    private var usageMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        animator = TreeAnimator(button: button)
        historyPanel.anchorButton = button

        let menu = NSMenu()
        self.menu = menu

        let initialStatus = SystemStatusView(
            cpuFraction: 0, cpuHistory: [], memFraction: 0, memHistory: [],
            memUsedGB: 0, memTotalGB: 0)
        let statusHost = NSHostingView(rootView: initialStatus)
        statusHost.frame.size = statusHost.fittingSize
        systemStatusHost = statusHost
        systemStatusItem = NSMenuItem()
        systemStatusItem.view = statusHost
        menu.addItem(systemStatusItem)
        menu.addItem(.separator())

        let historyItem = NSMenuItem(
            title: "클립보드 히스토리", action: #selector(showHistory), keyEquivalent: "V")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self
        menu.addItem(historyItem)

        let screenshotParent = NSMenuItem(title: "스크린샷 저장 방식", action: nil, keyEquivalent: "")
        let screenshotSub = NSMenu()
        screenshotBothItem = NSMenuItem(
            title: "다운로드 + 클립보드", action: #selector(setScreenshotModeBoth), keyEquivalent: "")
        screenshotBothItem.target = self
        screenshotClipItem = NSMenuItem(
            title: "클립보드만 (파일 저장 안 함)", action: #selector(setScreenshotModeClipboard),
            keyEquivalent: "")
        screenshotClipItem.target = self
        screenshotSub.addItem(screenshotBothItem)
        screenshotSub.addItem(screenshotClipItem)
        screenshotParent.submenu = screenshotSub
        menu.addItem(screenshotParent)
        refreshScreenshotMenu()

        menu.addItem(.separator())

        // 잠들지 않기 (Amphetamine)
        keepAwakeItem = NSMenuItem(title: "잠들지 않기", action: nil, keyEquivalent: "")
        let awakeSub = NSMenu()
        keepAwakeOptions = [
            ("무기한", nil), ("30분", 30), ("1시간", 60), ("2시간", 120), ("4시간", 240),
        ]
        for (i, opt) in keepAwakeOptions.enumerated() {
            let it = NSMenuItem(
                title: opt.title, action: #selector(setKeepAwake(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            awakeSub.addItem(it)
        }
        awakeSub.addItem(.separator())
        let offItem = NSMenuItem(
            title: "끄기", action: #selector(setKeepAwake(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.tag = -1
        awakeSub.addItem(offItem)
        keepAwakeItem.submenu = awakeSub
        menu.addItem(keepAwakeItem)
        keepAwake.onChange = { [weak self] in
            self?.refreshKeepAwakeMenu()
            self?.animator.setAwake(self?.keepAwake.isActive ?? false)
        }
        refreshKeepAwakeMenu()

        menu.addItem(.separator())

        let settingsMenu = NSMenu()
        let loginItem = NSMenuItem(
            title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsMenu.addItem(loginItem)

        let autoPasteItem = NSMenuItem(
            title: "히스토리 선택 시 자동 붙여넣기", action: #selector(toggleAutoPaste),
            keyEquivalent: "")
        autoPasteItem.target = self
        autoPasteItem.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        settingsMenu.addItem(autoPasteItem)

        settingsMenu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "히스토리 비우기 (핀 제외)", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        settingsMenu.addItem(clearItem)

        let settingsItem = NSMenuItem(title: "설정", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Shake Tree 종료", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self

        // 좌클릭 = 메뉴 열기, 우클릭(또는 control-클릭) = 잠들지 않기 토글.
        // 그래서 statusItem.menu 를 고정하지 않고 버튼 액션으로 직접 처리한다.
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        clipboardWatcher.start()
        // both 모드에서만 파일 감시가 필요하다 (clipboardOnly는 macOS가 직접 처리).
        if ScreenshotMode.current == .both { screenshotWatcher.start() }
        usageProvider.onUpdate = { [weak self] in self?.rebuildUsageMenuItems() }
        usageProvider.start()
        hotKey = HotKey { [weak self] in self?.historyPanel.toggle() }

        // accessory 앱은 분산 알림이 기본 보류되므로 즉시 전달로 등록 (스크립팅/테스트용)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowPanel),
            name: Notification.Name("dev.yubyeongju.shaketree.show-panel"), object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowMenu),
            name: Notification.Name("dev.yubyeongju.shaketree.show-menu"), object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleToggleAwake),
            name: Notification.Name("dev.yubyeongju.shaketree.toggle-awake"), object: nil,
            suspensionBehavior: .deliverImmediately)

        _ = cpuMonitor.sample()  // 첫 샘플은 델타 기준점만 잡음
        // 0.5초마다 샘플링 — 나무 흔들림이 CPU 변화를 촘촘하고 민감하게 따라가도록.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func refreshSystemStats() {
        let cpu = cpuMonitor.sample()
        animator.update(cpuUsage: cpu)
        let mem = memoryMonitor.sample()

        cpuHistory.append(cpu)
        if cpuHistory.count > historyCapacity { cpuHistory.removeFirst() }
        memHistory.append(mem.usedFraction)
        if memHistory.count > historyCapacity { memHistory.removeFirst() }

        // 평소엔 흑백 나무 그대로, CPU/RAM 중 하나라도 경고 수준이면 그때만 색을 입힌다.
        let level = SystemThresholds.worse(
            SystemThresholds.cpuLevel(cpu), SystemThresholds.ramLevel(mem.usedFraction))
        switch level {
        case .critical: animator.setWarningColor(.systemRed)
        case .warning: animator.setWarningColor(.systemOrange)
        case .normal: animator.setWarningColor(nil)
        }

        systemStatusHost.rootView = SystemStatusView(
            cpuFraction: cpu, cpuHistory: cpuHistory,
            memFraction: mem.usedFraction, memHistory: memHistory,
            memUsedGB: mem.usedGB, memTotalGB: mem.totalGB)
        systemStatusHost.frame.size = systemStatusHost.fittingSize
    }

    /// CPU 항목 아래(인덱스 2부터)에 사용량 게이지 + 상태 줄을 다시 채운다.
    private func rebuildUsageMenuItems() {
        for item in usageMenuItems { menu.removeItem(item) }
        usageMenuItems.removeAll()

        var index = 2
        for usage in usageProvider.usages {
            let item = NSMenuItem()
            let hostingView = NSHostingView(rootView: UsageMenuView(usage: usage))
            hostingView.frame.size = hostingView.fittingSize
            item.view = hostingView
            menu.insertItem(item, at: index)
            usageMenuItems.append(item)
            index += 1
        }

        let statusItem = NSMenuItem(
            title: usageProvider.statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.insertItem(statusItem, at: index)
        usageMenuItems.append(statusItem)
        menu.insertItem(.separator(), at: index + 1)
        usageMenuItems.append(menu.item(at: index + 1)!)
    }

    @objc private func showHistory() {
        historyPanel.show()
    }

    @objc private func handleShowPanel() {
        historyPanel.show()
    }

    @objc private func handleShowMenu() {
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.menu.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        openMenu()
    }

    @objc private func handleToggleAwake() {
        keepAwake.toggle()
    }

    /// 좌클릭=메뉴, 우클릭/control-클릭=잠들지 않기 토글
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight =
            event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            keepAwake.toggle()
        } else {
            openMenu()
        }
    }

    /// statusItem.menu 를 잠시 붙였다 떼는 방식으로 메뉴를 연다 (버튼 하이라이트 포함).
    private func openMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func setKeepAwake(_ sender: NSMenuItem) {
        if sender.tag < 0 {
            keepAwake.disable()
        } else {
            let minutes = keepAwakeOptions[sender.tag].minutes
            keepAwake.enable(duration: minutes.map { TimeInterval($0 * 60) })
        }
    }

    private func refreshKeepAwakeMenu() {
        let active = keepAwake.isActive
        // 부모 항목: 활성 상태 표시
        if active {
            if let endsAt = keepAwake.endsAt {
                let f = DateFormatter()
                f.locale = Locale(identifier: "ko_KR")
                f.dateFormat = "HH:mm"
                keepAwakeItem.title = "잠들지 않기 · \(f.string(from: endsAt))까지"
            } else {
                keepAwakeItem.title = "잠들지 않기 · 켜짐(무기한)"
            }
        } else {
            keepAwakeItem.title = "잠들지 않기"
        }
        keepAwakeItem.state = active ? .on : .off

        // 서브메뉴 체크마크: 무기한만 상태 표시(지속시간은 진행형이라 생략), 끄기는 비활성 시 체크
        for item in keepAwakeItem.submenu?.items ?? [] {
            if item.tag == 0 {
                item.state = (active && keepAwake.endsAt == nil) ? .on : .off
            } else if item.tag == -1 {
                item.state = active ? .off : .on
            } else {
                item.state = .off
            }
        }
    }

    @objc private func setScreenshotModeBoth() { applyScreenshotMode(.both) }
    @objc private func setScreenshotModeClipboard() { applyScreenshotMode(.clipboardOnly) }

    private func applyScreenshotMode(_ mode: ScreenshotMode) {
        let previous = ScreenshotMode.current
        UserDefaults.standard.set(mode.rawValue, forKey: "screenshotMode")
        ScreenshotWatcher.applyMode(mode)
        if mode == .both {
            screenshotWatcher.start()
        } else {
            screenshotWatcher.stop()
        }
        refreshScreenshotMenu()

        // 모드가 실제로 바뀐 첫 순간에만 안내 (썸네일 끔 + 각 모드 동작 설명)
        guard mode != previous else { return }
        let alert = NSAlert()
        alert.messageText = "스크린샷 저장 방식 변경됨"
        switch mode {
        case .both:
            alert.informativeText =
                "이제 스크린샷이 다운로드 폴더에 저장되고 동시에 클립보드에도 복사됩니다.\n"
                + "빠른 반영을 위해 캡처 후 뜨는 '미리보기 썸네일'은 꺼집니다."
        case .clipboardOnly:
            alert.informativeText =
                "이제 스크린샷이 파일로 저장되지 않고 클립보드로만 바로 복사됩니다.\n"
                + "빠른 반영을 위해 캡처 후 뜨는 '미리보기 썸네일'은 꺼집니다."
        }
        alert.runModal()
    }

    private func refreshScreenshotMenu() {
        let mode = ScreenshotMode.current
        screenshotBothItem?.state = (mode == .both) ? .on : .off
        screenshotClipItem?.state = (mode == .clipboardOnly) ? .on : .off
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목 변경 실패"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    @objc private func toggleAutoPaste(_ sender: NSMenuItem) {
        let newValue = !UserDefaults.standard.bool(forKey: "autoPaste")
        UserDefaults.standard.set(newValue, forKey: "autoPaste")
        sender.state = newValue ? .on : .off
        if newValue && !Paster.canPaste {
            Paster.requestAccessibilityPermission()
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "클립보드 히스토리 비우기"
        alert.informativeText = "핀 고정된 항목을 제외한 모든 히스토리를 삭제합니다."
        alert.addButton(withTitle: "비우기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            ClipboardStore.shared.deleteAllUnpinned()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
