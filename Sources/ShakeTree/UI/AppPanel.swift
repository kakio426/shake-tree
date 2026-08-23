import AppKit
import ServiceManagement
import SwiftUI

/// 메인 패널의 표시 상태와 동작. 뷰는 이 모델만 본다 — 서비스 연결(감시기 시작,
/// 패널 전환)은 AppDelegate가 주입한다. 종전에 AppDelegate가 하던 메뉴 갱신·알럿
/// 처리가 모두 여기로 모였다.
@MainActor
final class AppModel: ObservableObject {
    struct UsageState {
        var usages: [ProviderUsage] = []
        var statusText = ""
    }

    struct AwakeState: Equatable {
        var active = false
        var endsAt: Date?
    }

    // 자주 바뀌는 값은 섹션별 스냅샷 하나로 발행한다. 개별 @Published 12개를 연달아
    // 바꾸면 같은 화면이 한 샘플마다 여러 번 다시 배치된다.
    @Published private(set) var system = SystemSnapshot.empty

    // AI 사용량 (캐시를 즉시 표시하고, 패널 열기/저주기 백그라운드에서 갱신)
    @Published private(set) var usage = UsageState()

    // 잠들지 않기 — KeepAwake.onChange에서만 바뀐다 (private(set))
    @Published private(set) var awake = AwakeState()

    // 스크린샷 / 설정
    @Published var screenshotMode: ScreenshotMode = .current
    @Published private(set) var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @Published var autoPasteEnabled = UserDefaults.standard.bool(forKey: "autoPaste")

    // 주입 지점 — 인스턴스 서비스와 화면 전환은 AppDelegate가 연결한다
    var startScreenshotWatcher: ((Bool) -> Void)?
    var showHistoryPanel: (() -> Void)?

    private let keepAwake: KeepAwake

    init(keepAwake: KeepAwake) {
        self.keepAwake = keepAwake
    }

    func updateSystem(_ snapshot: SystemSnapshot) {
        guard snapshot != system else { return }
        system = snapshot
    }

    func updateUsage(_ usages: [ProviderUsage], statusText: String) {
        usage = UsageState(usages: usages, statusText: statusText)
    }

    func syncAwake(from service: KeepAwake) {
        let next = AwakeState(active: service.isActive, endsAt: service.endsAt)
        if next != awake { awake = next }
    }

    /// 토글 우클릭과 같은 의미의 빠른 on/off도 칩으로 통해서만 — nil이면 무기한.
    func enableAwake(minutes: Int?) {
        keepAwake.enable(duration: minutes.map { TimeInterval($0 * 60) })
    }

    func disableAwake() {
        keepAwake.disable()
    }

    /// 상태 줄 문구: 꺼짐 / 무기한 / HH:mm까지
    var awakeStateText: String {
        guard awake.active else { return "꺼짐" }
        return awake.endsAt.map { "\(Theme.clockText($0))까지" } ?? "무기한"
    }

    func setScreenshotMode(_ mode: ScreenshotMode) {
        screenshotMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "screenshotMode")
        ScreenshotWatcher.applyMode(mode)
        // both 모드에서만 파일 감시가 필요하다 (clipboardOnly는 macOS가 직접 처리).
        startScreenshotWatcher?(mode == .both)
    }

    func toggleLoginItem() {
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
            runModal(alert)
        }
        loginItemEnabled = service.status == .enabled
    }

    func toggleAutoPaste() {
        autoPasteEnabled.toggle()
        UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPaste")
        if autoPasteEnabled && !Paster.canPaste {
            Paster.requestAccessibilityPermission()
        }
    }

    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "클립보드 히스토리 비우기"
        alert.informativeText = "핀 고정된 항목을 제외한 모든 히스토리를 삭제합니다."
        alert.addButton(withTitle: "비우기")
        alert.addButton(withTitle: "취소")
        if runModal(alert) == .alertFirstButtonReturn {
            ClipboardStore.shared.deleteAllUnpinned()
        }
    }

    func showHistory() {
        showHistoryPanel?()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// 메인 패널은 앱을 활성화하지 않고 열리므로, 알럿을 띄울 때만 앞으로 가져온다.
    @discardableResult
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

/// 메인 드롭다운 패널 컨트롤러 — 종전의 NSMenu를 대체한다.
/// 좌클릭=열기/닫기, 포커스를 잃으면 닫힌다(메뉴처럼). esc 닫기도 지원.
@MainActor
final class MainPanelController {
    /// 메뉴바 아이콘 버튼 — 이 아래로 패널이 떨어진다.
    weak var anchorButton: NSStatusBarButton?

    private var panel: FloatingPanel?
    private var pendingHeight: CGFloat?
    private var resizeScheduled = false
    private var panelGeneration = 0
    /// 패널이 만들어질 때 등록한 관찰자·모니터 해제 클로저. close()와 앱 종료 경로가
    /// 모두 이 클로저를 실행하므로 actor 격리를 우회하는 deinit 정리가 필요 없다.
    private var cleanup: (() -> Void)?
    /// 포커스 이동으로 자동 닫힌 직후의 시각 — 아이콘 재클릭으로 닫을 때
    /// "닫힘→재오픈"이 겹쳐 절대 닫히지 않는 버그를 막는 유예 창.
    private var lastAutoClose = Date.distantPast

    /// AppDelegate가 화면용 발행과 느린 조회를 패널이 보일 때만 수행하도록 알려준다.
    var onVisibilityChange: ((Bool) -> Void)?

    private let model: AppModel

    /// 수명주기 진단과 회귀 테스트용. 닫힌 뒤 false여야 숨은 SwiftUI 트리가 없다.
    var hasLoadedPanel: Bool { panel != nil }

    init(model: AppModel) {
        self.model = model
    }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard Date().timeIntervalSince(lastAutoClose) > 0.35 else { return }
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        onVisibilityChange?(true)
        panelGeneration &+= 1
        let panel = makePanel()
        self.panel = panel

        // 내용 크기에 맞춰 세운 뒤 메뉴바 아래에 붙인다 (세부 보정은 레이아웃 직후 콜백)
        if let host = panel.contentView as? NSHostingView<MainPanelView> {
            let size = host.fittingSize
            panel.setContentSize(
                NSSize(width: Theme.panelWidth, height: max(size.height, 100)))
        }
        panel.positionBelow(anchorButton: anchorButton)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }

        // orderOut만 하면 NSHostingView와 모든 관찰이 살아 있어, 숨은 패널이 시스템
        // 샘플마다 계속 레이아웃된다. 관찰자부터 끊고 콘텐츠를 실제로 해제한다.
        cleanup?()
        cleanup = nil
        self.panel = nil
        panelGeneration &+= 1
        pendingHeight = nil
        resizeScheduled = false
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        onVisibilityChange?(false)
    }

    private func makePanel() -> FloatingPanel {
        let host = NSHostingView(
            rootView: MainPanelView(
                model: model,
                onClose: { [weak self] in self?.close() },
                onHeightChange: { [weak self] height in
                    self?.scheduleResize(to: height)
                }))
        let panel = FloatingPanel.makePopover(contentView: host, width: Theme.panelWidth)

        // 바깥을 클릭해 포커스를 잃으면 닫힌다 (메뉴처럼)
        let resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastAutoClose = Date()
                self?.close()
            }
        }

        // esc로 닫기 — 패널이 키 윈도우일 때만 가로챈다
        let escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }  // 53 = esc
            var handled = false
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, panel.isVisible, panel.isKeyWindow {
                    self.close()
                    handled = true
                }
            }
            return handled ? nil : event
        }

        cleanup = { [resignKeyObserver, escMonitor] in
            NotificationCenter.default.removeObserver(resignKeyObserver)
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        }

        return panel
    }

    /// GeometryReader 콜백 안에서 곧바로 창 프레임을 바꾸면 새 레이아웃이 다시 같은
    /// 콜백을 부르는 순환이 생길 수 있다. 한 런루프에 한 번으로 합쳐 다음 턴에 적용한다.
    private func scheduleResize(to height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        pendingHeight = height.rounded(.up)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        let generation = panelGeneration

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.panelGeneration == generation else { return }
                self.resizeScheduled = false
                guard let height = self.pendingHeight else { return }
                self.pendingHeight = nil
                guard let panel = self.panel, panel.isVisible else { return }
                panel.resizeKeepingTop(to: height)
            }
        }
    }
}
