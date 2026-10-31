import Foundation

struct DiskUsage: Sendable {
    /// 정리 가능 영역도 포함하는 물리적 점유량. 스왑과 합계를 맞추는 기준이다.
    let usedFraction: Double  // 0...1
    let usedGB: Double
    let totalGB: Double
    /// 캐시·스냅샷 등 시스템이 당장 회수할 수 있는 영역. raw statfs 사용량은
    /// 이만큼 더 커서, 그냥 보여주면 Finder와 숫자가 어긋나 보인다.
    let purgeableGB: Double
}

/// 부팅 볼륨의 저장공간 사용량.
/// 즉시 가용량으로 물리적 점유를 계산한다. 정리 가능 영역은 점유량 안에
/// 포함되므로 게이지와 파일/스왑 합계에서 두 번 더하지 않는다.
final class DiskMonitor: Sendable {
    func sample() -> DiskUsage {
        let url = FileManager.default.homeDirectoryForCurrentUser
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
        let available = values.volumeAvailableCapacity.map(Double.init) ?? Double(important)
        let usedBytes = min(totalBytes, max(0, totalBytes - available))

        var purgeableBytes: Double = 0
        if let rawAvailable = values.volumeAvailableCapacity {
            purgeableBytes = min(usedBytes, max(0, Double(important) - Double(rawAvailable)))
        }

        return DiskUsage(
            usedFraction: totalBytes > 0 ? usedBytes / totalBytes : 0,
            usedGB: usedBytes / 1_000_000_000,
            totalGB: totalBytes / 1_000_000_000,
            purgeableGB: purgeableBytes / 1_000_000_000)
    }
}
