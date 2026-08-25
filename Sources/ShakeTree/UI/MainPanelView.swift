import SwiftUI

/// 메인 드롭다운 — 종전의 NSMenu 전체를 하나의 패널로 재구성했다.
/// 위에서부터: 시스템 현황 → AI 사용량 → 동작 → 설정 → 푸터. 섹션마다 같은
/// 여백·헤더 리듬을 쓴다.
struct MainPanelView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("시스템") {
                SystemStatusView(snapshot: model.system)
            }
            Divider()
            section("AI 사용량") { usageContent }
            Divider()
            ActionSection(model: model)
            Divider()
            SettingsSection(model: model)
            Divider()
            footer
        }
        .frame(width: Theme.panelWidth)
        // 부모 창 높이가 콘텐츠 측정값을 다시 바꾸지 않도록 세로 크기는 intrinsic size로
        // 고정한다. AppKit 패널 리사이즈와 SwiftUI 측정 사이의 피드백 가능성을 줄인다.
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(.separator, lineWidth: 1))
        // 높이가 내용에 따라 변하면(사용량 도착, 섹션 펼침) 상단을 고정한 채 늘어난다
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeightChange($0) }
    }

    /// 공통 섹션 바디 — 작은 헤더 + 내용, 모든 섹션이 같은 패딩을 쓴다.
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .textCase(nil)
            content()
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, Theme.blockPadding)
    }

    @ViewBuilder
    private var usageContent: some View {
        if !model.usage.usages.isEmpty {
            UsageGridView(usages: model.usage.usages)
        }
        // 데이터 전/후 공통 상태 줄 — "조회 중…" / "업데이트: 오후 3:04" / 실패 안내
        Text(model.usage.statusText)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var footer: some View {
        HStack {
            Text(Self.versionText)
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button(action: { model.quit() }) {
                Text("종료")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 7)
    }

    private static let versionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        guard let version, let build else { return "Shake Tree" }
        return "Shake Tree \(version) (\(build))"
    }()
}

// MARK: - 동작 섹션

private struct ActionSection: View {
    @ObservedObject var model: AppModel
    @State private var awakeExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(
                icon: "moon.zzz", title: "잠들지 않기",
                action: {
                    withAnimation(.easeInOut(duration: 0.15)) { awakeExpanded.toggle() }
                }
            ) {
                HStack(spacing: 4) {
                    Text(model.awakeStateText)
                        .font(Theme.captionStrong)
                        .foregroundStyle(
                            model.awake.active ? Color.accentColor : Color.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(awakeExpanded ? 180 : 0))
                }
            }
            if awakeExpanded {
                AwakeDurationGrid(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            PanelRow(
                icon: "doc.on.clipboard", title: "클립보드 히스토리",
                action: { model.showHistory() }
            ) {
                Text("⇧⌘V")
                    .font(Theme.microDigit)
                    .foregroundStyle(.tertiary)
            }

            PanelRow(icon: "camera", title: "스크린샷") {
                Picker("", selection: Binding(
                    get: { model.screenshotMode },
                    set: { model.setScreenshotMode($0) }
                )) {
                    Text("파일+클립보드").tag(ScreenshotMode.both)
                    Text("클립보드만").tag(ScreenshotMode.clipboardOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 172)
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, Theme.blockPadding)
    }
}

/// 지속 시간 칩 — 종전 서브메뉴와 같은 선택지. 진행 중인 지속시간은 endsAt만 남아
/// 어느 칩을 골랐는지 알 수 없어(종전에도 체크하지 않았음) 무기한/끄기만 상태를 비춘다.
private struct AwakeDurationGrid: View {
    @ObservedObject var model: AppModel

    private let options: [(title: String, minutes: Int?)] =
        [("무기한", nil), ("30분", 30), ("1시간", 60), ("2시간", 120), ("4시간", 240)]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
            spacing: 6
        ) {
            ForEach(options.indices, id: \.self) { index in
                chip(options[index].title, selected: isSelected(options[index])) {
                    model.enableAwake(minutes: options[index].minutes)
                }
            }
            chip("끄기", selected: !model.awake.active) { model.disableAwake() }
        }
        .padding(.leading, 24)  // 아이콘 열만큼 들여쓰기
        .padding(.vertical, 2)
    }

    private func isSelected(_ option: (title: String, minutes: Int?)) -> Bool {
        option.minutes == nil && model.awake.active && model.awake.endsAt == nil
    }

    private func chip(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chipFont)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                )
                .overlay(
                    Capsule().strokeBorder(
                        selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 아이콘 + 제목 + 오른쪽 보조 요소 한 줄. action이 있으면 버튼으로 동작하며 호버
/// 배경이 생기고, 없으면(컨트롤이 오른쪽에 있는 행) 그냥 정적 레이아웃이 된다.
private struct PanelRow<Trailing: View>: View {
    let icon: String
    let title: String
    let action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    @State private var hovering = false

    init(
        icon: String, title: String, action: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        let row = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(Theme.body)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())

        row
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && action != nil ? Color.primary.opacity(0.06) : Color.clear)
            )
            .onHover { hovering = $0 }
            .wrapInButton(action: action)
    }
}

extension View {
    /// action이 있으면 버튼으로 감싼다 — PanelRow의 조건부 래핑 헬퍼.
    @ViewBuilder
    fileprivate func wrapInButton(action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) { self }.buttonStyle(.plain)
        } else {
            self
        }
    }
}

// MARK: - 설정 섹션

private struct SettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(
                icon: "gearshape", title: "설정",
                action: {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            ) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(
                        "로그인 시 자동 실행",
                        isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { _ in model.toggleLoginItem() })
                    )
                    .font(Theme.body)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(
                        "히스토리 선택 시 자동 붙여넣기",
                        isOn: Binding(
                            get: { model.autoPasteEnabled },
                            set: { _ in model.toggleAutoPaste() })
                    )
                    .font(Theme.body)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Button(role: .destructive, action: { model.clearHistory() }) {
                        Text("히스토리 비우기 (핀 제외)")
                            .font(Theme.body)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, Theme.blockPadding)
    }
}
