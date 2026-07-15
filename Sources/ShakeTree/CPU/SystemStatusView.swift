import SwiftUI

/// 메뉴 맨 위 CPU/RAM 표시.
/// CPU는 메뉴바 나무가 이미 흔들림으로 상태를 보여주므로 여기선 단색 그래프로 둔다.
/// RAM은 그 자체로는 아무 표시가 없으니, 위험 수준일 때만 색을 준다 — 단 RAM은
/// 캐시 때문에 평소에도 70%대에 머무는 게 정상이라 CPU보다 훨씬 높은 기준선을 쓴다.
struct SystemStatusView: View {
    let cpuFraction: Double  // 0...1
    let cpuHistory: [Double]
    let memFraction: Double
    let memHistory: [Double]
    let memUsedGB: Double
    let memTotalGB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(
                icon: "cpu", label: "CPU", history: cpuHistory, color: .primary,
                detail: percentText(cpuFraction), detailColor: .primary)
            row(
                icon: "memorychip", label: "RAM", history: memHistory, color: ramColor,
                detail: String(format: "%.1f/%.0fGB", memUsedGB, memTotalGB),
                detailColor: ramColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
    }

    private func percentText(_ f: Double) -> String {
        "\(Int((f * 100).rounded()))%"
    }

    /// RAM 전용 기준선(SystemThresholds 공용 정의) — CPU보다 높게 잡은 이유는 macOS가
    /// 여유 메모리를 디스크 캐시로 적극 활용해서 평소에도 70%대가 정상이기 때문.
    private var ramColor: Color {
        switch SystemThresholds.ramLevel(memFraction) {
        case .critical: .red
        case .warning: .orange
        case .normal: .primary
        }
    }

    private func row(
        icon: String, label: String, history: [Double], color: Color,
        detail: String, detailColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)

            Sparkline(values: history, color: color)
                .frame(height: 22)

            Text(detail)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(detailColor)
                .frame(minWidth: 70, alignment: .trailing)
        }
    }
}
