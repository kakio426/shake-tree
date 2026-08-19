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
    let memCompressedGB: Double
    let swapUsedGB: Double
    let diskFraction: Double
    let diskUsedGB: Double
    let diskTotalGB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            graphRow(
                icon: "cpu", label: "CPU", history: cpuHistory, color: .primary,
                detail: percentText(cpuFraction), detailColor: .primary)
            // RAM은 두 줄: 사용량 그래프 + 압축/스왑 보조 줄. 램이 꽉 찬 맥에서는
            // 사용량 GB가 천장에 붙어 거의 안 움직이는 게 정상이라, 실제로 상태를
            // 알려주는 압축·스왑을 바로 아래 붙여둔다.
            VStack(alignment: .leading, spacing: 1) {
                graphRow(
                    icon: "memorychip", label: "RAM", history: memHistory, color: ramColor,
                    detail: gbText(memUsedGB, memTotalGB), detailColor: ramColor)
                memoryDetailRow()
            }
            meterRow(
                icon: "internaldrive", label: "저장", fraction: diskFraction, color: diskColor,
                detail: gbText(diskUsedGB, diskTotalGB))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
    }

    private func percentText(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    /// 총량이 작을수록(=RAM) 소수 한 자리까지 — 17GB짜리를 정수로 반올림하면
    /// 1GB 미만의 변화가 통째로 사라져서 값이 멈춰 있는 것처럼 보인다.
    /// 수백 GB짜리 디스크는 반대로 소수점이 지저분하기만 하므로 정수로 둔다.
    private func gbText(_ used: Double, _ total: Double) -> String {
        total < 100
            ? String(format: "%.1f/%.0fGB", used, total)
            : String(format: "%.0f/%.0fGB", used, total)
    }

    private var ramColor: Color { color(for: memLevel) }

    /// 압축 메모리는 항상, 스왑은 실제로 쓰이고 있을 때만 표시 —
    /// 스왑 0인 건 건강한 상태라 굳이 자리를 차지할 이유가 없다.
    private var memoryDetailText: String {
        var parts = [String(format: "압축 %.1fGB", memCompressedGB)]
        if swapUsedGB >= 0.05 { parts.append(String(format: "스왑 %.1fGB", swapUsedGB)) }
        return parts.joined(separator: "  ·  ")
    }

    private func memoryDetailRow() -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 56, height: 0)  // 위 행의 라벨 폭만큼 들여쓰기
            Text(memoryDetailText)
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(memLevel == .normal ? Color.secondary : ramColor)
            Spacer(minLength: 0)
        }
    }

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
