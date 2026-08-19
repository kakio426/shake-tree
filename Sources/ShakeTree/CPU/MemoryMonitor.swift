import Darwin
import Foundation

struct MemoryUsage: Sendable {
    let usedFraction: Double  // 0...1
    let usedGB: Double
    let totalGB: Double
    let compressedGB: Double
}

/// vm_statistics64로 Activity Monitor의 "메모리 사용량"과 같은 정의로 계산한다:
/// used = 앱 메모리(internal - purgeable) + 유선(wired) + 압축됨(compressor).
///
/// 예전엔 `total - free - purgeable - speculative - inactive`로 빼서 구했는데 두 가지가 틀렸다.
/// (1) `host_statistics64`의 `free_count`는 speculative를 이미 포함한 값이라(vm_stat 명령이
///     표시할 때 빼주는 것뿐) speculative를 또 더하면 free를 이중으로 세서 사용량이 낮게 나온다.
/// (2) 더 근본적으로, 총량에서 회수 가능한 페이지를 빼는 방식은 결과가 파일 캐시(inactive)
///     크기에 좌우된다. 메모리가 꽉 찬 맥에서는 free가 0에 붙어 있어서 사용량이 사실상
///     "총량 - 캐시"가 되고, 앱이 메모리를 더 써도 캐시가 같이 줄어 값이 거의 안 움직인다.
///     Activity Monitor처럼 실제 사용 중인 페이지를 직접 더하면 앱 메모리 변화가 그대로 반영된다.
///
/// 참고: inactive에는 재사용 가능한 파일 캐시뿐 아니라 익명 페이지도 섞여 있어서, 통째로
/// 빼면 앱이 실제로 잡고 있는 메모리까지 빠진다. internal(익명) 기준으로 세면 이 문제가 없다.
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
            return MemoryUsage(usedFraction: 0, usedGB: 0, totalGB: totalGB, compressedGB: 0)
        }

        // 앱 메모리: 익명(파일에 대응되지 않는) 페이지에서 폐기 가능한 purgeable을 뺀 값
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = anonymous > purgeable ? anonymous - purgeable : 0

        let compressedPages = UInt64(stats.compressor_page_count)
        let usedPages = appPages + UInt64(stats.wire_count) + compressedPages
        let usedBytes = min(usedPages * UInt64(pageSize), totalBytes)
        let fraction = Double(usedBytes) / Double(totalBytes)

        return MemoryUsage(
            usedFraction: min(max(fraction, 0), 1),
            usedGB: Double(usedBytes) / 1_000_000_000,
            totalGB: totalGB,
            compressedGB: Double(compressedPages * UInt64(pageSize)) / 1_000_000_000)
    }
}
