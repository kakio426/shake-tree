import SwiftUI

/// 메뉴 맨 위 시스템 상태 표시.
/// CPU/RAM은 시간에 따라 변하는 활동량이라 미니 그래프(sparkline)로, 디스크는 "얼마나
/// 찼나"라는 정적인 용량이라 채움 막대(meter)로 보여준다. 셋 다 평소엔 단색이고,
/// 위험 수준일 때만 색을 준다 — 아래 AI 사용량의 상시 색상 게이지와 구분된다.
/// (RAM/디스크는 평소에도 높게 유지되는 게 정상이라 CPU보다 높은 경고 기준선을 쓴다.)
struct SystemStatusView: View {
    let cpuFraction: Double  // 0...1
    let cpuHistory: [Double]
    let memHistory: [Double]
    let memLevel: UsageLevel  // 사용량 %가 아니라 커널의 실제 메모리 압박 신호
    let memUsedGB: Double
    let memTotalGB: Double
    let diskFraction: Double
    let diskUsedGB: Double
    let diskTotalGB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            graphRow(
                icon: "cpu", label: "CPU", history: cpuHistory, color: .primary,
                detail: percentText(cpuFraction), detailColor: .primary)
            graphRow(
                icon: "memorychip", label: "RAM", history: memHistory, color: ramColor,
                detail: gbText(memUsedGB, memTotalGB), detailColor: ramColor)
            meterRow(
                icon: "internaldrive", label: "저장", fraction: diskFraction, color: diskColor,
                detail: gbText(diskUsedGB, diskTotalGB))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
    }

    private func percentText(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    private func gbText(_ used: Double, _ total: Double) -> String {
        String(format: "%.0f/%.0fGB", used, total)
    }

    private var ramColor: Color { color(for: memLevel) }
    private var diskColor: Color { color(for: SystemThresholds.diskLevel(diskFraction)) }

    private func color(for level: UsageLevel) -> Color {
        switch level {
        case .critical: .red
        case .warning: .orange
        case .normal: .primary
        }
    }

    // CPU/RAM: 시간 추이 그래프
    private func graphRow(
        icon: String, label: String, history: [Double], color: Color,
        detail: String, detailColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            rowLabel(icon: icon, text: label)
            Sparkline(values: history, color: color)
                .frame(height: 22)
            detailText(detail, color: detailColor)
        }
    }

    // 디스크: 얼마나 찼는지 채움 막대
    private func meterRow(
        icon: String, label: String, fraction: Double, color: Color, detail: String
    ) -> some View {
        HStack(spacing: 10) {
            rowLabel(icon: icon, text: label)
            ThinProgressBar(value: fraction, color: color, height: 6)
                .frame(height: 22)
            detailText(detail, color: color)
        }
    }

    private func rowLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(width: 56, alignment: .leading)
    }

    private func detailText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .frame(minWidth: 74, alignment: .trailing)
    }
}
