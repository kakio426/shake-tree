import AppKit
import SwiftUI

enum SettingsPage: Hashable { case general, resources, awake }
enum DetailPage {
    case system, usage(String)
    var isSystem: Bool { if case .system = self { true } else { false } }
    var provider: String? { if case let .usage(provider) = self { provider } else { nil } }
}

/// Closed utility windows release their hosting trees and subscriptions, just like the menubar.
@MainActor
final class UtilityWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClose: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var lastVisible = false
    private(set) weak var hostedViewForDiagnostics: NSView?

    func show(title: String, size: NSSize, content: AnyView) {
        let window: NSWindow
        if let current = self.window { window = current }
        else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: size.width, height: min(size.height, 480))
            window.delegate = self
            window.center()
            self.window = window
        }
        if let host = window.contentView as? NSHostingView<AnyView> { host.rootView = content }
        else { window.contentView = NSHostingView(rootView: content) }
        hostedViewForDiagnostics = window.contentView
        window.title = title
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reportVisibility()
    }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        if let host = window?.contentView as? NSHostingView<AnyView> { host.rootView = AnyView(EmptyView()) }
        window?.contentView = nil
        window = nil
        onClose?()
        reportVisibility()
    }
    func windowDidMiniaturize(_ notification: Notification) { reportVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { reportVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { reportVisibility() }
    private func reportVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        guard visible != lastVisible else { return }
        lastVisible = visible
        onVisibilityChange?(visible)
    }
}

struct SettingsWindowView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsPage
    @State private var minutes = 60

    init(model: AppModel, page: SettingsPage) {
        self.model = model
        _selection = State(initialValue: page)
    }
    var body: some View {
        TabView(selection: $selection) {
            general.tabItem { Label("일반", systemImage: "gearshape") }.tag(SettingsPage.general)
            resources.tabItem { Label("자원 사용", systemImage: "leaf") }.tag(SettingsPage.resources)
            awake.tabItem { Label("잠들지 않기", systemImage: "moon.zzz") }.tag(SettingsPage.awake)
        }
        .padding(12)
        .frame(minWidth: 440, minHeight: 360)
    }
    private var general: some View {
        Form {
            Section("시작 및 캡처") {
                Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.loginItemEnabled }, set: { _ in model.toggleLoginItem() }))
                Picker("스크린샷", selection: Binding(get: { model.screenshotMode }, set: { model.setScreenshotMode($0) })) {
                    Text("파일+클립보드").tag(ScreenshotMode.both)
                    Text("클립보드만").tag(ScreenshotMode.clipboardOnly)
                }
            }
            Section("클립보드") {
                Toggle("선택 시 자동 붙여넣기", isOn: Binding(get: { model.autoPasteEnabled }, set: { _ in model.toggleAutoPaste() }))
                Button("히스토리 비우기 (핀 제외)", role: .destructive) { model.clearHistory() }
            }
            Section {
                HStack {
                    Text("Shake Tree \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "개발 버전")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("앱 종료") { model.quit() }
                }
            }
        }
        .formStyle(.grouped)
    }
    private var resources: some View {
        Form {
            Section("시스템") {
                resourceToggle("절전 모드", \.economy)
                resourceToggle("시스템 모니터링", \.systemEnabled)
                resourceToggle("나무 애니메이션", \.animationEnabled)
                Text("절전 모드는 패널이 닫히면 5초, 열리면 2초 간격으로 수집합니다. 저전력·높은 온도에서는 수집을 더 늦추고 움직임을 멈춥니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("기록 및 조회") {
                resourceToggle("클립보드 기록", \.clipboardEnabled)
                resourceToggle("AI 사용량 조회", \.usageEnabled)
                Text("화면 잠금·꺼짐 중에는 수집과 클립보드 확인을 멈춥니다. 패널이나 상세 창을 닫으면 진행 중인 AI 조회도 중단합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    private var awake: some View {
        Form {
            Section {
                LabeledContent("현재 상태") { AwakeStatusView(state: model.awake) }
                Picker("열려 있을 때 화면", selection: Binding(get: { model.awake.mode }, set: { model.setAwakeMode($0) })) {
                    ForEach(AwakeMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                resourceToggle("덮개를 닫아도 Mac 유지", \.lidAwakeEnabled)
                if case let .failed(message) = model.awake.lidStatus {
                    Text(message).foregroundStyle(.orange)
                } else if model.awake.active && model.resources.lidAwakeEnabled {
                    switch model.awake.lidStatus {
                    case .active: Text("덮개를 닫아도 계속 실행 중").foregroundStyle(.secondary)
                    case .external: Text("다른 전원 설정이 덮개 닫힘 잠자기를 막고 있습니다").foregroundStyle(.secondary)
                    case .preparing, .stopping: Text("덮개 닫힘 설정 확인 중…").foregroundStyle(.secondary)
                    case .failed: EmptyView()
                    case .off: EmptyView()
                    }
                }
                HStack {
                    TextField("지속 시간", value: $minutes, format: .number).frame(maxWidth: 160)
                        .onSubmit { if validMinutes { model.enableAwake(minutes: minutes) } }
                    Text("분").foregroundStyle(.secondary)
                    Spacer()
                    Button("시작") { model.enableAwake(minutes: minutes) }.disabled(!validMinutes)
                    Button("끄기") { model.disableAwake() }.disabled(!model.awake.active)
                }
                Text("1분~24시간. 덮개 유지 중에는 수동 잠자기도 막습니다. 화면 보호기와 잠금은 macOS 설정을 따릅니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("세션 관리") {
                resourceToggle("배터리 20% 이하에서 자동 종료", \.lowBatteryProtection)
                resourceToggle("중단된 세션 복원", \.restoreInterruptedAwake)
                Text("온도가 위험 수준이면 자동 종료됩니다. 정상 종료 시 세션은 해제되며, 중단된 세션은 24시간 안에 시작했고 아직 유효할 때만 복원합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let text = model.awake.error ?? model.awake.notice {
                Text(text).font(.caption).foregroundStyle(model.awake.error == nil ? Color.secondary : .orange)
            }
        }
        .formStyle(.grouped)
    }
    private var validMinutes: Bool { (1...1440).contains(minutes) }
    private func resourceToggle(_ title: String, _ key: WritableKeyPath<ResourceSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.resources[keyPath: key] }, set: { model.setResource(key, to: $0) }))
    }
}

struct DetailWindowView: View {
    @ObservedObject var model: AppModel
    let page: DetailPage
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch page {
                case .system:
                    SystemDetailView(state: model.systemState)
                case let .usage(provider):
                    UsageGridView(usages: model.usage.usages.filter { $0.provider == provider },
                                  isRefreshing: model.usage.isRefreshing, singleColumn: true) {
                        model.refreshUsageProvider?($0)
                    }
                    if model.usage.isRefreshing {
                        Button("조회 취소") { model.cancelUsageRefresh?() }
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 340, minHeight: 260)
    }
}

private struct SystemDetailView: View {
    @ObservedObject var state: SystemStateModel
    var body: some View { SystemStatusView(snapshot: state.snapshot) }
}
