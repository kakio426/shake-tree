import CoreGraphics

/// 메뉴 안 커스텀 뷰들의 공통 치수. NSMenu의 폭은 가장 넓은 항목이 결정하므로,
/// 항목마다 제각각 폭을 쓰면 좁은 쪽 오른편에 빈 공간이 남아 어긋나 보인다.
enum MenuMetrics {
    /// 사용량 게이지를 2열로 놓을 수 있는 폭. 모든 메뉴 항목이 이 값을 쓴다.
    static let panelWidth: CGFloat = 440
    static let horizontalPadding: CGFloat = 14
    /// 2열 배치에서 한 칸의 폭.
    static let columnSpacing: CGFloat = 16
    static var columnWidth: CGFloat {
        (panelWidth - horizontalPadding * 2 - columnSpacing) / 2
    }
}
