import AppKit
import SwiftUI

/// 클립보드 히스토리 플로팅 패널 — 검색·선택·자동 붙여넣기를 담당한다.
/// 패널 외관과 위치잡기는 공용 FloatingPanel이 맡는다.
@MainActor
final class HistoryPanelController {
    private var panel: FloatingPanel?
    private let viewModel = HistoryViewModel()
    private var resignObserver: NSObjectProtocol?
    /// 패널을 열기 직전에 앞에 있던 앱 — 붙여넣기/포커스 복귀 대상
    private var previousApp: NSRunningApplication?
    /// 포커스 이동으로 자동 닫힌 직후 시각 — 아이콘 재클릭 시 "닫힘→재오픈"
    /// 충돌을 막는 유예 창용 (메인 패널과 같은 규칙).
    private var lastAutoClose = Date.distantPast

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
        guard Date().timeIntervalSince(lastAutoClose) > 0.35 else { return }
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // 활성화 직전의 앞 앱을 기억 (붙여넣기/포커스 복귀 대상)
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        let panel = makePanel()
        self.panel = panel
        viewModel.prepareForPresentation()
        panel.positionBelow(anchorButton: anchorButton)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        self.panel = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        // 이미지 항목은 각각 큰 PNG일 수 있다. 닫힌 히스토리 패널이 목록 전체의 BLOB을
        // 계속 잡고 있지 않도록 화면용 배열을 비운다. DB 기록에는 영향이 없다.
        viewModel.unload()
        previousApp = nil
    }

    private func makePanel() -> FloatingPanel {
        let host = NSHostingView(rootView: HistoryView(model: viewModel))
        let panel = FloatingPanel.makePopover(
            contentView: host, width: Self.panelWidth)

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
            MainActor.assumeIsolated {
                self?.lastAutoClose = Date()
                self?.close()
            }
        }

        return panel
    }
}

// MARK: - 뷰모델

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var selectedIndex: Int = 0
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            reload()
            selectedIndex = 0
        }
    }

    var onSelect: ((ClipboardItem) -> Void)?
    var onClose: (() -> Void)?

    func prepareForPresentation() {
        if searchText.isEmpty {
            reload()
        } else {
            searchText = ""
        }
        selectedIndex = 0
    }

    func unload() {
        items = []
        selectedIndex = 0
    }

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
