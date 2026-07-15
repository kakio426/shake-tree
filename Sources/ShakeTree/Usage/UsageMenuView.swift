import SwiftUI

/// 메뉴 안에 들어가는 프로바이더별 사용량 게이지 뷰
struct UsageMenuView: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(providerName).font(.system(size: 13, weight: .semibold))
                if let plan = usage.plan {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach(usage.windows) { window in
                let remaining = max(0, 100 - window.usedPercent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(window.label).font(.caption)
                        Spacer()
                        if let reset = window.resetText {
                            Text(reset).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(Int(remaining))% 남음")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(gaugeColor(remaining))
                    }
                    // 배터리처럼 남은 양이 줄어드는 게이지
                    ThinProgressBar(value: remaining / 100, color: gaugeColor(remaining))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    private var providerName: String {
        switch usage.provider {
        case "codex": "Codex"
        case "claude": "Claude"
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
