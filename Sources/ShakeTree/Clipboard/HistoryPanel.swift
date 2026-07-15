import AppKit
import SwiftUI

/// 앱을 활성화하지 않고도 키 입력을 받는 플로팅 패널.
/// 닫으면 포커스가 원래 앱으로 자연스럽게 돌아가 바로 붙여넣기가 가능하다.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HistoryPanelController {
    private var panel: FloatingPanel?
    private let viewModel = HistoryViewModel()
    private var resignObserver: NSObjectProtocol?
    /// 패널을 열기 직전에 앞에 있던 앱 — 붙여넣기/포커스 복귀 대상
    private var previousApp: NSRunningApplication?

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 440

    /// 메뉴바 아이콘 버튼 — 이 아래로 패널이 떨어진다.
    weak var anchorButton: NSStatusBarButton?

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        // 활성화 직전의 앞 앱을 기억 (붙여넣기/포커스 복귀 대상)
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        viewModel.reload()
        viewModel.searchText = ""
        viewModel.selectedIndex = 0
        positionUnderMenuBar(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        viewModel.onSelect = { [weak self] item in
            ClipboardWatcher.copyToPasteboard(item)
            let autoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
            let target = self?.previousApp
            self?.close()
            // 직전 앱으로 포커스를 되돌린다
            target?.activate()
            if autoPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Paster.pasteToFrontmostApp()
                }
            }
        }
        viewModel.onClose = { [weak self] in
            let target = self?.previousApp
            self?.close()
            target?.activate()
        }

        // 바깥을 클릭해 포커스를 잃으면 닫힌다 (메뉴처럼)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        let host = NSHostingView(rootView: HistoryView(model: viewModel))
        panel.contentView = host
        return panel
    }

    /// 메뉴바 아이콘 바로 아래에, 화면 밖으로 넘치지 않게 위치시킨다.
    private func positionUnderMenuBar(_ panel: NSPanel) {
        let size = panel.frame.size
        let screen =
            anchorButton?.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x: CGFloat
        if let buttonFrame = anchorButton?.window?.frame {
            // 아이콘 중심에 패널을 맞추되 오른쪽 가장자리를 살짝 넘어가지 않게
            x = buttonFrame.midX - size.width / 2
        } else {
            x = visible.maxX - size.width - 8
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height  // 상단(메뉴바 바로 아래)에 붙임
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 뷰모델

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var selectedIndex: Int = 0
    @Published var searchText: String = "" {
        didSet {
            reload()
            selectedIndex = 0
        }
    }

    var onSelect: ((ClipboardItem) -> Void)?
    var onClose: (() -> Void)?

    func reload() {
        items = ClipboardStore.shared.items(matching: searchText)
        if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
    }

    func selectCurrent() {
        guard items.indices.contains(selectedIndex) else { return }
        onSelect?(items[selectedIndex])
    }

    /// ⌘숫자로 바로 선택
    func activate(index: Int) {
        guard items.indices.contains(index) else { return }
        onSelect?(items[index])
    }

    func togglePin(_ item: ClipboardItem) {
        ClipboardStore.shared.setPinned(!item.pinned, id: item.id)
        reload()
    }

    func delete(_ item: ClipboardItem) {
        ClipboardStore.shared.delete(id: item.id)
        reload()
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }
}

// MARK: - 뷰

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("클립보드 검색…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.selectCurrent() }
            }
            .font(.system(size: 15))
            .padding(12)

            Divider()

            if model.items.isEmpty {
                Spacer()
                Text(model.searchText.isEmpty ? "복사한 항목이 여기에 쌓입니다" : "검색 결과 없음")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) {
                                index, item in
                                HistoryRow(
                                    item: item,
                                    isSelected: index == model.selectedIndex,
                                    shortcut: index < 9 ? index + 1 : nil
                                )
                                .id(item.id)
                                .onTapGesture {
                                    model.selectedIndex = index
                                    model.selectCurrent()
                                }
                                .onHover { hovering in
                                    if hovering { model.selectedIndex = index }
                                }
                                .contextMenu {
                                    Button(item.pinned ? "핀 해제" : "핀 고정") {
                                        model.togglePin(item)
                                    }
                                    Button("삭제", role: .destructive) { model.delete(item) }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selectedIndex) { _, newIndex in
                        if model.items.indices.contains(newIndex) {
                            proxy.scrollTo(model.items[newIndex].id)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Text("↑↓ 이동 · ⏎ 붙여넣기 · ⌘1–9 바로 선택 · esc 닫기")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: HistoryPanelController.panelWidth, height: HistoryPanelController.panelHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(1)
            return .handled
        }
        .onKeyPress(.escape) {
            model.onClose?()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // ⌘1–9 로 해당 항목 즉시 선택
            if press.modifiers.contains(.command),
                let n = Int(press.characters), (1...9).contains(n)
            {
                model.activate(index: n - 1)
                return .handled
            }
            return .ignored
        }
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let shortcut: Int?

    var body: some View {
        HStack(spacing: 8) {
            content

            Spacer(minLength: 8)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .orange)
            }
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: item.kind == .image ? 42 : 30)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .image, let data = item.imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .frame(maxWidth: 240, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text(item.previewLine)
                .lineLimit(1)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : .primary)
        }
    }
}
