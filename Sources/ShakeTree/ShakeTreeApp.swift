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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            Task { @MainActor in self?.refreshSystemStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    /// 모델의 주입 지점에 실제 서비스를 연결한다.
    private func wireModel() {
        model.startScreenshotWatcher = { [screenshotWatcher] start in
            start ? screenshotWatcher.start() : screenshotWatcher.stop()
        }
        model.showHistoryPanel = { [historyPanel] in historyPanel.show() }

        // 사용량 조회 결과가 바뀔 때마다 모델로 밀어 넣는다 (→ 패널 자동 갱신)
        model.usageStatusText = usageProvider.statusText
        usageProvider.onUpdate = { [weak self] in
            guard let self else { return }
            self.model.usages = self.usageProvider.usages
            self.model.usageStatusText = self.usageProvider.statusText
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
            Task { @MainActor in self?.mainPanel.close() }
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

    private func refreshSystemStats() {
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
        animator.setWarningColor(Theme.warningColor(for: level))

        let swap = swapMonitor.sample()
        let disk = diskMonitor.sample()
        model.cpuFraction = cpu
        model.cpuHistory = cpuHistory
        model.memHistory = memHistory
        model.memLevel = memoryPressureMonitor.level
        model.memUsedGB = mem.usedGB
        model.memTotalGB = mem.totalGB
        model.memCompressedGB = mem.compressedGB
        model.swapUsedGB = swap.usedGB
        model.diskFraction = disk.usedFraction
        model.diskUsedGB = disk.usedGB
        model.diskTotalGB = disk.totalGB
        model.diskPurgeableGB = disk.purgeableGB
    }
}
