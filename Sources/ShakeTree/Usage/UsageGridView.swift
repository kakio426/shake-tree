import SwiftUI

/// AI 사용량 섹션 본문 — 프로바이더별 사용량을 2열로 배치한다. 예전엔 프로바이더마다
/// 메뉴 항목을 하나씩 만들어 세로로 쌓았는데, Grok·Antigravity까지 붙으면서 메뉴가
/// 지나치게 길어졌다. 칸 높이는 프로바이더가 가진 한도 창 수에 따라 달라서 위쪽으로 정렬.
struct UsageGridView: View {
    let usages: [ProviderUsage]

    private var rows: [[ProviderUsage]] {
        stride(from: 0, to: usages.count, by: 2).map {
            Array(usages[$0..<min($0 + 2, usages.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Theme.columnSpacing) {
                    ForEach(row) { usage in
                        ProviderUsageCell(usage: usage)
                            .frame(width: Theme.columnWidth, alignment: .topLeading)
                    }
                    // 홀수 개면 마지막 줄 오른쪽 칸을 비워 왼쪽 칸이 늘어나지 않게 한다
                    if row.count == 1 {
                        Color.clear.frame(width: Theme.columnWidth, height: 0)
                    }
                }
            }
        }
    }
}

/// 한 칸: 프로바이더 이름 + 요금제, 그 아래 한도 창별 게이지.
/// 잘 안 쓰는 부가 한도(Spark)는 접혀 있고, 토글 행을 눌러야 펼쳐진다.
private struct ProviderUsageCell: View {
    let usage: ProviderUsage

    @State private var sparkExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(providerName).font(Theme.cardTitle)
                if let plan = usage.plan {
                    Text(plan)
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ForEach(usage.windows) { window in
                usageWindow(window)
            }
            if !usage.sparkWindows.isEmpty {
                sparkDisclosure
            }
        }
    }

    /// 접힌 부가 한도 — 평소엔 한 줄짜리 토글만 보인다.
    @ViewBuilder
    private var sparkDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { sparkExpanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(sparkExpanded ? 180 : 0))
                Text("Spark")
                    .font(Theme.micro)
                    .lineLimit(1)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if sparkExpanded {
            ForEach(usage.sparkWindows) { window in
                usageWindow(window)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func usageWindow(_ window: ProviderUsage.WindowDisplay) -> some View {
        let remaining = max(0, 100 - window.usedPercent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(Theme.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(Theme.remainingText(remaining))
                    .font(Theme.captionStrong)
                    .foregroundStyle(Theme.gaugeColor(remainingPercent: remaining))
                    .lineLimit(1)
            }
            // 리셋 시각은 게이지 옆에 둔다. 제목 줄에 같이 놓으면 긴 제목
            // ("Claude/GPT 세션")과 겹쳐 한 칸의 폭이 그만큼 넓어져야 한다.
            HStack(spacing: 5) {
                // 배터리처럼 남은 양이 줄어드는 게이지
                ThinProgressBar(
                    value: remaining / 100,
                    color: Theme.gaugeColor(remainingPercent: remaining), height: 4)
                if let reset = window.resetText {
                    Text(reset)
                        .font(Theme.microDigit)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    private var providerName: String {
        switch usage.provider {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "grok": "Grok"
        case "gemini": "Gemini"
        default: usage.provider.capitalized
        }
    }
}
