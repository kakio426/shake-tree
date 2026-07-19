import Foundation

struct DiskUsage: Sendable {
    let usedFraction: Double  // 0...1
    let usedGB: Double
    let totalGB: Double
}

/// 부팅 볼륨의 저장공간 사용량. Finder의 "사용 가능"과 맞추기 위해
/// volumeAvailableCapacityForImportantUsage(정리 가능 공간 반영)를 쓴다.
@MainActor
final class DiskMonitor {
    func sample() -> DiskUsage {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return DiskUsage(usedFraction: 0, usedGB: 0, totalGB: 0)
        }
        let totalBytes = Double(total)
        let usedBytes = max(0, totalBytes - Double(available))
        return DiskUsage(
            usedFraction: totalBytes > 0 ? usedBytes / totalBytes : 0,
            usedGB: usedBytes / 1_000_000_000,
            totalGB: totalBytes / 1_000_000_000)
    }
}
