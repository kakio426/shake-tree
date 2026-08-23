/// 패널에 한 번에 전달하는 시스템 상태. 샘플러는 계속 최신 값을 모으되 SwiftUI에는
/// 이 값 하나만 발행해서, 한 번의 측정이 여러 차례 레이아웃을 일으키지 않게 한다.
struct SystemSnapshot: Equatable, Sendable {
    var cpuFraction: Double
    var cpuHistory: [Double]
    var memHistory: [Double]
    var memLevel: UsageLevel
    var memUsedGB: Double
    var memTotalGB: Double
    var memCompressedGB: Double
    var swapUsedGB: Double
    var diskFraction: Double
    var diskUsedGB: Double
    var diskTotalGB: Double
    var diskPurgeableGB: Double

    static let empty = SystemSnapshot(
        cpuFraction: 0, cpuHistory: [], memHistory: [], memLevel: .normal,
        memUsedGB: 0, memTotalGB: 0, memCompressedGB: 0, swapUsedGB: 0,
        diskFraction: 0, diskUsedGB: 0, diskTotalGB: 0, diskPurgeableGB: 0)
}
