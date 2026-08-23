import Foundation

struct DiskUsage: Sendable {
    /// 정리 가능 공간을 제외한 실사용 비율 — Finder의 "사용 가능"과 같은 기준.
    let usedFraction: Double  // 0...1
    let usedGB: Double
    let totalGB: Double
    /// 캐시·스냅샷 등 시스템이 당장 회수할 수 있는 영역. raw statfs 사용량은
    /// 이만큼 더 커서, 그냥 보여주면 Finder와 숫자가 어긋나 보인다.
    let purgeableGB: Double
}

/// 부팅 볼륨의 저장공간 사용량.
/// Finder식 가용(volumeAvailableCapacityForImportantUsage, 정리 가능 포함)로 실사용을
/// 계산하고, 순수 가용(volumeAvailableCapacity)과의 차이를 "정리 가능" 영역으로
/// 분리해 함께 돌려준다 — 게이지에서 두 색으로 갈라 보여주기 위함.
@MainActor
final class DiskMonitor {
    func sample() -> DiskUsage {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity,
            let important = values.volumeAvailableCapacityForImportantUsage
        else {
            return DiskUsage(usedFraction: 0, usedGB: 0, totalGB: 0, purgeableGB: 0)
        }

        let totalBytes = Double(total)
        let usedBytes = max(0, totalBytes - Double(important))

        var purgeableBytes: Double = 0
        if let rawAvailable = values.volumeAvailableCapacity {
            purgeableBytes = max(0, totalBytes - Double(rawAvailable) - usedBytes)
        }

        return DiskUsage(
            usedFraction: totalBytes > 0 ? usedBytes / totalBytes : 0,
            usedGB: usedBytes / 1_000_000_000,
            totalGB: totalBytes / 1_000_000_000,
            purgeableGB: purgeableBytes / 1_000_000_000)
    }
}
