import SwiftUI

/// SwiftUI 기본 ProgressView(.linear)는 메뉴 안에서 두꺼워 보이므로,
/// 높이를 직접 통제할 수 있는 얇은 막대를 대신 쓴다.
struct ThinProgressBar: View {
    let value: Double  // 0...1
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}
