import Darwin
import Foundation

/// host_statistics의 CPU 틱 델타로 전체 CPU 사용률(0.0~1.0)을 계산한다.
@MainActor
final class CPUMonitor {
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func sample() -> Double {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let current = (
            user: info.cpu_ticks.0, system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2, nice: info.cpu_ticks.3
        )
        defer { previousTicks = current }
        guard let prev = previousTicks else { return 0 }

        let user = Double(current.user &- prev.user)
        let system = Double(current.system &- prev.system)
        let idle = Double(current.idle &- prev.idle)
        let nice = Double(current.nice &- prev.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total
    }
}
