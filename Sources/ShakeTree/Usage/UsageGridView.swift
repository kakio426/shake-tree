import SwiftUI

/// 프로바이더별 사용량을 2열로 배치한다. 예전엔 프로바이더마다 메뉴 항목을 하나씩
/// 만들어 세로로 쌓았는데, Grok·Antigravity까지 붙으면서 메뉴가 지나치게 길어졌다.
/// 칸 높이는 프로바이더가 가진 한도 창 수에 따라 달라서 위쪽으로 정렬한다.
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
                HStack(alignment: .top, spacing: MenuMetrics.columnSpacing) {
                    ForEach(row) { usage in
                        ProviderUsageCell(usage: usage)
                            .frame(width: MenuMetrics.columnWidth, alignment: .topLeading)
                    }
                    // 홀수 개면 마지막 줄 오른쪽 칸을 비워 왼쪽 칸이 늘어나지 않게 한다
                    if row.count == 1 {
                        Color.clear.frame(width: MenuMetrics.columnWidth, height: 0)
                    }
                }
            }
        }
        .padding(.horizontal, MenuMetrics.horizontalPadding)
        .padding(.vertical, 8)
        .frame(width: MenuMetrics.panelWidth, alignment: .leading)
    }
}

/// 한 칸: 프로바이더 이름 + 요금제, 그 아래 한도 창별 게이지
private struct ProviderUsageCell: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(providerName).font(.system(size: 12, weight: .semibold))
                if let plan = usage.plan {
                    Text(plan)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ForEach(usage.windows) { window in
                let remaining = max(0, 100 - window.usedPercent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.label)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 2)
                        Text("\(Int(remaining))% 남음")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(gaugeColor(remaining))
                            .lineLimit(1)
                    }
                    // 리셋 시각은 게이지 옆에 둔다. 제목 줄에 같이 놓으면 긴 제목
                    // ("Claude/GPT 세션")과 겹쳐 한 칸의 폭이 그만큼 넓어져야 한다.
                    HStack(spacing: 5) {
                        // 배터리처럼 남은 양이 줄어드는 게이지
                        ThinProgressBar(
                            value: remaining / 100, color: gaugeColor(remaining), height: 4)
                        if let reset = window.resetText {
                            Text(reset)
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private var providerName: String {
        switch usage.provider {
        case "codex": "Codex"
        case "claude": "Claude"
        case "grok": "Grok"
        case "antigravity": "Antigravity"  // Gemini 한도는 여기로 잡힌다
        default: usage.provider.capitalized
        }
    }

    /// 남은 비율 기준: 적게 남을수록 위험(빨강)
    private func gaugeColor(_ remaining: Double) -> Color {
        switch remaining {
        case ..<10: .red
        case ..<30: .orange
        default: .green
        }
    }
}
