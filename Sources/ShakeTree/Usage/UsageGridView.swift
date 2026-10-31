import SwiftUI

struct UsageGridView: View, Equatable {
    let usages: [ProviderUsage]
    let isRefreshing: Bool
    let singleColumn: Bool
    let onRefreshProvider: (String) -> Void
    init(usages: [ProviderUsage], isRefreshing: Bool = false, singleColumn: Bool = false,
         onRefreshProvider: @escaping (String) -> Void = { _ in }) {
        self.usages = usages
        self.isRefreshing = isRefreshing
        self.singleColumn = singleColumn
        self.onRefreshProvider = onRefreshProvider
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usages == rhs.usages && lhs.isRefreshing == rhs.isRefreshing && lhs.singleColumn == rhs.singleColumn
    }
    static func visibleUsages(_ usages: [ProviderUsage]) -> [ProviderUsage] {
        usages.filter { !($0.provider == "gemini" && $0.isNotice) }
    }
    private var compactRows: [[ProviderUsage]] {
        let compact = Self.visibleUsages(usages).filter { $0.provider != "antigravity" }
        return stride(from: 0, to: compact.count, by: 2).map { Array(compact[$0..<min($0 + 2, compact.count)]) }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: isRefreshing ? 1 : 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
              if singleColumn {
                ForEach(Self.visibleUsages(usages)) { usage in cell(usage, now: context.date) }
              } else {
                if let first = compactRows.first { compactRow(first, now: context.date) }
                if let antigravity = usages.first(where: { $0.provider == "antigravity" }) {
                    cell(antigravity, now: context.date)
                }
                ForEach(Array(compactRows.dropFirst().enumerated()), id: \.offset) { _, row in
                    compactRow(row, now: context.date)
                }
              }
            }
        }
    }
    private func cell(_ usage: ProviderUsage, now: Date) -> some View {
        ProviderUsageCell(usage: usage, now: now, isRefreshing: isRefreshing) {
            onRefreshProvider(usage.provider)
        }
    }
    private func compactRow(_ row: [ProviderUsage], now: Date) -> some View {
        HStack(alignment: .top, spacing: Theme.columnSpacing) {
            ForEach(row) { usage in
                cell(usage, now: now).frame(width: Theme.columnWidth, alignment: .topLeading)
            }
            if row.count == 1 { Color.clear.frame(width: Theme.columnWidth, height: 0) }
        }
    }
}

private struct ProviderUsageCell: View {
    let usage: ProviderUsage
    let now: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @State private var sparkExpanded = false
    @State private var historyExpanded = false
    private var hasCurrentValues: Bool { usage.hasCurrentValues(at: now) }
    private var groups: [String] {
        usage.windows.reduce(into: [String]()) { result, window in
            let group = usage.displayGroup(window.group) ?? "한도"
            if !result.contains(group) { result.append(group) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(providerName).font(Theme.cardTitle).lineLimit(1)
                if let plan = usage.plan {
                    Text(plan).font(Theme.micro).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").font(Theme.micro)
                }
                .buttonStyle(.plain).disabled(isRefreshing)
                .help("\(providerName) 새로고침").accessibilityLabel("\(providerName) 새로고침")
            }
            if let account = usage.account {
                Text(account).font(Theme.micro).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(account)
            }
            if hasCurrentValues {
                currentWindows
            } else {
                Text(usage.refreshState.isPending ? "새 사용량을 확인하고 있습니다." : "최신 사용량을 확인해 주세요.")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !usage.refreshState.isPending, !usage.windows.isEmpty {
                    DisclosureGroup("이전 기록 보기", isExpanded: $historyExpanded) {
                        ForEach(usage.windows) { window in
                            Text("\(usage.displayGroup(window.group).map { $0 + " · " } ?? "")\(window.label): 이전 \(Int((100 - window.usedPercent).rounded()))% 남음")
                                .font(Theme.micro).foregroundStyle(.secondary)
                        }
                    }
                    .font(Theme.micro)
                }
            }
            if let pending = usage.refreshState.text(at: now) {
                Text(pending).font(Theme.microDigit).foregroundStyle(.secondary)
            } else if let issue = usage.issue {
                Text(issue).font(Theme.micro).foregroundStyle(usage.isNotice ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = usage.lastObservationText(at: now) {
                Text(last).font(Theme.microDigit).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    @ViewBuilder
    private var currentWindows: some View {
        if usage.provider == "antigravity", !usage.windows.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 9) {
                ForEach(groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        if group == ProviderUsage.externalSharedGroupTitle {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group).font(Theme.captionStrong).foregroundStyle(.secondary)
                                Text("안티그래비티의 Claude 등")
                                    .font(Theme.micro).foregroundStyle(.secondary)
                            }
                            .help(ProviderUsage.externalSharedGroupExplanation)
                            .accessibilityElement(children: .combine)
                        } else if group == "Gemini" {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group).font(Theme.captionStrong).foregroundStyle(.secondary)
                                Text("안티그래비티 전용").font(Theme.micro).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            Text(group).font(Theme.captionStrong).foregroundStyle(.secondary)
                        }
                        ForEach(usage.windows.filter { (usage.displayGroup($0.group) ?? "한도") == group }) { usageWindow($0) }
                    }
                }
            }
        } else {
            ForEach(usage.windows) { window in
                if let group = usage.displayGroup(window.group) { Text(group).font(Theme.micro).foregroundStyle(.secondary) }
                usageWindow(window)
            }
        }
        if !usage.sparkWindows.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { sparkExpanded.toggle() }
            } label: {
                Label("Spark", systemImage: sparkExpanded ? "chevron.up" : "chevron.down")
                    .font(Theme.micro).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if sparkExpanded { ForEach(usage.sparkWindows) { usageWindow($0) } }
        }
    }
    private func usageWindow(_ window: ProviderUsage.WindowDisplay) -> some View {
        let remaining = min(100, max(0, 100 - window.usedPercent))
        let measured = usage.canShow(window, at: now)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.label).font(Theme.caption).lineLimit(1)
                Spacer(minLength: 2)
                Text(measured ? Theme.remainingText(remaining) : "—")
                    .font(Theme.captionStrong)
                    .foregroundStyle(measured ? Theme.gaugeColor(remainingPercent: remaining) : .secondary)
                    .lineLimit(1)
            }
            if measured {
                ThinProgressBar(value: remaining / 100,
                    color: Theme.gaugeColor(remainingPercent: remaining), height: 4)
            }
            if let reset = window.resetText(at: now) {
                Text(measured ? reset : "리셋 시각 지남")
                    .font(Theme.microDigit).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .opacity(usage.issue == nil ? 1 : 0.65)
    }
    private var providerName: String {
        switch usage.provider {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "antigravity": "Antigravity"
        case "grok": "Grok"
        case "gemini": "Gemini CLI"
        default: usage.provider.capitalized
        }
    }
}
