import Darwin
import Foundation

struct MemoryUsage: Sendable {
    let usedFraction: Double  // 0...1
    let usedGB: Double
    let totalGB: Double
}

/// vm_statistics64로 실제 사용 중인 메모리를 macOS `top`/Activity Monitor와 같은 정의로 계산한다:
/// used = total - free - purgeable - speculative.
///
/// 예전엔 "active + wired + compressed"만 더했는데, 이러면 inactive 페이지(재사용 가능한
/// 파일 캐시 등, macOS 자신은 "사용 중"으로 집계함)가 빠져서 실제보다 몇 GB씩 낮게 나오고
/// 거의 안 변하는 것처럼 보였다 (예: 16GB 중 실제 15.7GB 사용인데 11.9GB로 표시).
@MainActor
final class MemoryMonitor {
    private let totalBytes: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }()

    func sample() -> MemoryUsage {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let totalGB = Double(totalBytes) / 1_000_000_000

        guard result == KERN_SUCCESS, totalBytes > 0 else {
            return MemoryUsage(usedFraction: 0, usedGB: 0, totalGB: totalGB)
        }

        let freePages =
            UInt64(stats.free_count) + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        let totalPages = totalBytes / UInt64(pageSize)
        let usedPages = totalPages > freePages ? totalPages - freePages : 0
        let usedBytes = usedPages * UInt64(pageSize)
        let fraction = Double(usedBytes) / Double(totalBytes)

        return MemoryUsage(
            usedFraction: min(max(fraction, 0), 1),
            usedGB: Double(usedBytes) / 1_000_000_000,
            totalGB: totalGB)
    }
}
