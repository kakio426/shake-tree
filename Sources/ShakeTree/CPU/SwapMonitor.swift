import Darwin
import Foundation

struct SwapUsage: Sendable {
    let usedGB: Double
    let totalGB: Double
}

/// 스왑(디스크로 밀려난 메모리) 사용량 — `sysctl vm.swapusage`와 같은 값.
///
/// 사용률(used/total)로 경고를 매기지 않는다: macOS의 스왑 파일은 고정 크기가 아니라
/// 필요하면 디스크 여유 공간 한도까지 알아서 커진다. "8GB 중 6.9GB"의 86%는 위험 신호가
/// 아니라 지금 파일이 그만큼 잡혀 있다는 뜻일 뿐이다. 절대량만 보여주고 색 판정은
/// 커널의 메모리 압박 신호(MemoryPressureMonitor)에 맡긴다.
@MainActor
final class SwapMonitor {
    func sample() -> SwapUsage {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &len, nil, 0) == 0 else {
            return SwapUsage(usedGB: 0, totalGB: 0)
        }
        return SwapUsage(
            usedGB: Double(usage.xsu_used) / 1_000_000_000,
            totalGB: Double(usage.xsu_total) / 1_000_000_000)
    }
}
