import SwiftUI

/// The menubar is a compact overview. Graphs, accounts and individual quotas live in inspectors.
struct MainPanelView: View {
    @ObservedObject var model: AppModel
    var maximumHeight: CGFloat = 700
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Shake Tree").font(Theme.captionStrong).foregroundStyle(.secondary)
                    Spacer()
                    Button("설정…") { model.openSettings(.general) }
                        .font(Theme.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                if model.resources.systemEnabled {
                    Button { model.openDetails(.system) } label: {
                        CompactSystemView(state: model.systemState)
                    }
                    .buttonStyle(.plain).help("시스템 자세히")
                    .padding(.horizontal, 14).padding(.bottom, 12)
                    Divider()
                }
                if model.resources.usageEnabled {
                    CompactUsageView(model: model).padding(.horizontal, 14).padding(.vertical, 8)
                    Divider()
                }
                awakeMenu.padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                Button { model.showHistory() } label: {
                    HStack {
                        Label("클립보드", systemImage: "doc.on.clipboard")
                        Spacer()
                        Text("⇧⌘V").foregroundStyle(.tertiary)
                    }
                    .font(Theme.body).contentShape(Rectangle())
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .frame(width: Theme.panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .frame(width: Theme.panelWidth, height: min(max(contentHeight, 100), max(180, maximumHeight)))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(.separator, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeightChange($0) }
    }

    private var awakeMenu: some View {
      HStack(spacing: 6) {
        Menu {
            if model.awake.active { Button("잠자기 방지 끄기") { model.disableAwake() }; Divider() }
            Button("무기한") { model.enableAwake(minutes: nil) }
            ForEach([30, 60, 120, 240], id: \.self) { minutes in
                Button(minutes < 60 ? "\(minutes)분" : "\(minutes / 60)시간") { model.enableAwake(minutes: minutes) }
            }
            Divider()
            Button("시간·화면 설정…") { model.openSettings(.awake) }
        } label: {
            Label("잠들지 않기", systemImage: "moon.zzz")
        }
        .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
        Spacer(minLength: 4)
        AwakeStatusView(state: model.awake)
      }
    }
}

private struct CompactSystemView: View {
    @ObservedObject var state: SystemStateModel
    private var snapshot: SystemSnapshot { state.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    metric("CPU", Theme.percentText(snapshot.cpuFraction))
                    Sparkline(values: snapshot.cpuHistory, color: Theme.color(for: SystemThresholds.cpuLevel(snapshot.cpuFraction)))
                        .frame(height: 18)
                }
                VStack(alignment: .leading, spacing: 5) {
                    metric("RAM", String(format: "%.1f/%.0fGB", snapshot.memUsedGB, snapshot.memTotalGB))
                    Sparkline(values: snapshot.memHistory, color: Theme.color(for: snapshot.memLevel)).frame(height: 18)
                }
                VStack(alignment: .leading, spacing: 5) {
                    metric("저장", snapshot.diskTotalGB > 0 ? String(format: "%.0f/%.0fGB", snapshot.diskUsedGB, snapshot.diskTotalGB) : "확인 중")
                    storageMeter.frame(height: 5).frame(height: 18)
                }
            }
            if snapshot.diskTotalGB > 0 {
                HStack(spacing: 6) {
                    Text(String(format: "파일·시스템 %.1fGB", snapshot.storage.fileSystemGB))
                    Spacer(minLength: 0)
                    Text(String(format: "스왑 파일 %.1fGB", snapshot.storage.swapGB))
                        .foregroundStyle(.blue)
                }
                .font(Theme.microDigit).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
    private var storageMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.color(for: SystemThresholds.diskLevel(snapshot.diskFraction)))
                        .frame(width: proxy.size.width * snapshot.storage.ordinaryFraction)
                    Rectangle().fill(Color.blue).frame(width: proxy.size.width * snapshot.storage.swapFraction)
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: proxy.size.width * snapshot.storage.purgeableFraction)
                }
            }
            .clipShape(Capsule())
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            Text(value).font(Theme.number).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactUsageView: View {
    @ObservedObject var model: AppModel
    struct SummarySnapshot: Equatable {
        let window: ProviderUsage.WindowDisplay
        let isCurrent: Bool
    }
    static func summaryWindow(_ usage: ProviderUsage, at now: Date) -> ProviderUsage.WindowDisplay? {
        usage.windows.filter { usage.canShow($0, at: now) }.max { $0.usedPercent < $1.usedPercent }
    }
    static func summarySnapshot(_ usage: ProviderUsage, at now: Date) -> SummarySnapshot? {
        if usage.issue == nil, let current = summaryWindow(usage, at: now) {
            return SummarySnapshot(window: current, isCurrent: true)
        }
        guard usage.fetchedAt != nil else { return nil }
        let windows = usage.windows.filter { $0.resetsAt.map { $0 > now } ?? true }
        guard let previous = (windows.isEmpty ? usage.windows : windows).max(by: { $0.usedPercent < $1.usedPercent }) else {
            return nil
        }
        return SummarySnapshot(window: previous, isCurrent: false)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: model.usage.isRefreshing ? 15 : 60)) { context in
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("AI 남은 한도").font(Theme.captionStrong).foregroundStyle(.secondary)
                    Spacer()
                    if let progress = model.usage.progress {
                        Text(progress.text(at: context.date)).font(Theme.microDigit).foregroundStyle(.secondary)
                    }
                    Button {
                        model.usage.isRefreshing ? model.cancelUsageRefresh?() : model.refreshUsage?()
                    } label: {
                        Image(systemName: model.usage.isRefreshing ? "xmark" : "arrow.clockwise")
                            .font(Theme.caption).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain).accessibilityLabel(model.usage.isRefreshing ? "사용량 조회 취소" : "사용량 새로고침")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(UsageGridView.visibleUsages(model.usage.usages)) { usage in
                        summaryCard(usage, now: context.date)
                    }
                }
            }
        }
    }
    private func summaryCard(_ usage: ProviderUsage, now: Date) -> some View {
        let snapshot = Self.summarySnapshot(usage, at: now)
        return Button { model.openDetails(.usage(usage.provider)) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(usage.displayName).font(Theme.cardTitle).lineLimit(1)
                    if usage.issue != nil && !usage.isNotice {
                        Image(systemName: "exclamationmark.circle").font(Theme.caption).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.tertiary)
                }
                if let snapshot {
                    let window = snapshot.window
                    let remaining = 100 - window.usedPercent
                    let color = snapshot.isCurrent ? Theme.gaugeColor(remainingPercent: remaining) : Color.secondary
                    HStack(spacing: 3) {
                        Text((snapshot.isCurrent ? "" : "이전 값 · ") + context(usage, window))
                            .font(Theme.micro).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Text(Theme.remainingText(remaining)).font(Theme.captionStrong)
                            .foregroundStyle(color).fixedSize()
                    }
                    ThinProgressBar(value: remaining / 100, color: color)
                        .opacity(snapshot.isCurrent ? 1 : 0.45).frame(height: 4)
                } else {
                    Text(usage.refreshState.isPending ? "백그라운드 확인 중" : "재조회 필요")
                        .font(Theme.caption).foregroundStyle(.secondary)
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 4)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((usage.lastObservationText(at: now) ?? "아직 조회 전") + " · 이전 값은 회색으로 표시 · 눌러서 전체 한도 확인")
    }
    private func context(_ usage: ProviderUsage, _ window: ProviderUsage.WindowDisplay) -> String {
        let group = usage.displayGroup(window.group).map { $0 == ProviderUsage.externalSharedGroupTitle ? "외부 모델" : $0 }
        return [group, window.label].compactMap { $0 }.joined(separator: " · ")
    }
}

struct AwakeStatusView: View {
    let state: AppModel.AwakeState
    private var detail: String {
        guard state.lidEnabled else { return state.mode.title }
        switch state.lidStatus {
        case .active, .external: return "덮개 유지"
        case .preparing, .stopping: return "덮개 확인 중"
        case .failed: return "덮개 유지 실패"
        case .off: return state.mode.title
        }
    }
    var body: some View {
        Group {
            if state.active, let end = state.endsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let minutes = max(0, Int(ceil(end.timeIntervalSince(context.date) / 60)))
                    Text("\(minutes)분 · \(detail)").help("\(Theme.clockText(end))까지 · \(state.mode.title)")
                }
            } else {
                Text(state.active ? "무기한 · \(detail)" : inactiveText).help(state.mode.title)
            }
        }
        .font(Theme.caption).foregroundStyle({
            if case .failed = state.lidStatus { return Color.orange }
            return state.active ? Color.accentColor : Color.secondary
        }())
    }
    private var inactiveText: String {
        if case .failed = state.lidStatus { return "해제 확인 필요" }
        return "꺼짐"
    }
}
