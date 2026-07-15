import Darwin
import Foundation

struct MemoryUsage: Sendable {
    let usedFraction: Double  // 0...1
    let usedGB: Double
    let totalGB: Double
}

/// vm_statistics64로 실제 사용 중인 메모리(활성+wired+압축)를 추정한다.
/// Activity Monitor의 "메모리 사용량"과 대략 같은 근사치.
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

        let usedPages =
            UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)
        let fraction = Double(usedBytes) / Double(totalBytes)

        return MemoryUsage(
            usedFraction: min(max(fraction, 0), 1),
            usedGB: Double(usedBytes) / 1_000_000_000,
            totalGB: totalGB)
    }
}
