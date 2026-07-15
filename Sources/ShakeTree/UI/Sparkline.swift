import SwiftUI

/// CPU/RAM용 미니 그래프. 기본은 흑백 톤(AI 사용량의 초록/주황/빨강 게이지와 섞이지
/// 않도록)이지만, 필요하면 경고색을 줘서 위험 수준만 강조할 수 있다(예: RAM 과부하).
struct Sparkline: View {
    let values: [Double]  // 0...1, 오래된 값이 먼저
    var color: Color = .primary

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let stepX = size.width / CGFloat(values.count - 1)

            var line = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(
                    x: CGFloat(i) * stepX, y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(fill, with: .color(color.opacity(0.14)))
            context.stroke(line, with: .color(color.opacity(0.85)), lineWidth: 1.4)
        }
    }
}
