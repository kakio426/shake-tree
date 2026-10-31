import Foundation

/// Owns sampling, caches and its timer independently of clipboard and UI state.
@MainActor
final class SystemMetricsService {
    private let cpu = CPUMonitor()
    private let memory = MemoryMonitor()
    private let pressure = MemoryPressureMonitor()
    private let swap = SwapMonitor()
    private let disk = DiskMonitor()
    private var timer: Timer?
    private var diskTask: Task<Void, Never>?
    private var policy = ResourcePolicy(settings: .init(), power: .init(), visible: false, suspended: true)
    private var visible = false
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var latestCPU = 0.0
    private var latestMemory: MemoryUsage?
    private var latestSwap: SwapUsage?
    private var latestDisk: DiskUsage?
    private var lastMemory = Date.distantPast
    private var lastSwap = Date.distantPast
    private var lastDisk = Date.distantPast
    var onSnapshot: ((SystemSnapshot) -> Void)?
    var onIcon: ((Double, UsageLevel) -> Void)?
    var samplingIntervalForDiagnostics: TimeInterval? { timer == nil ? nil : policy.sampleInterval }

    func configure(policy next: ResourcePolicy, visible: Bool) {
        let becameVisible = visible && !self.visible
        self.visible = visible
        let reschedule = policy.sampleInterval != next.sampleInterval || timer == nil
        policy = next
        guard let interval = next.sampleInterval else {
            timer?.invalidate()
            timer = nil
            pressure.stop()
            return
        }
        pressure.start()
        if reschedule {
            timer?.invalidate()
            cpu.reset()
            _ = cpu.sample()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer.tolerance = min(0.5, interval * 0.15)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if becameVisible { sample(includeCPU: false) }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        pressure.stop()
        diskTask?.cancel()
        diskTask = nil
    }
    private func sample(includeCPU: Bool = true) {
        guard policy.sampleInterval != nil else { return }
        let now = Date()
        if includeCPU {
            latestCPU = cpu.sample()
            cpuHistory.append(latestCPU)
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        }
        if latestMemory == nil || now.timeIntervalSince(lastMemory) >= policy.memoryInterval {
            latestMemory = memory.sample()
            lastMemory = now
        }
        guard let latestMemory else { return }
        if includeCPU {
            memoryHistory.append(latestMemory.usedFraction)
            if memoryHistory.count > 60 { memoryHistory.removeFirst() }
        }
        onIcon?(latestCPU, SystemThresholds.worse(SystemThresholds.cpuLevel(latestCPU), pressure.level))
        guard visible else { return }
        if latestSwap == nil || now.timeIntervalSince(lastSwap) >= 5 {
            latestSwap = swap.sample()
            lastSwap = now
        }
        if (latestDisk == nil || now.timeIntervalSince(lastDisk) >= 120), diskTask == nil {
            let disk = disk
            diskTask = Task { [weak self] in
                let result = await Task.detached(priority: .utility) { disk.sample() }.value
                guard let self, !Task.isCancelled else { return }
                self.diskTask = nil
                self.lastDisk = Date()
                if result.totalGB > 0 { self.latestDisk = result }
                if self.visible, self.policy.sampleInterval != nil { self.publish() }
            }
        }
        publish()
    }
    private func publish() {
        guard let memory = latestMemory else { return }
        onSnapshot?(SystemSnapshot(
            cpuFraction: latestCPU, cpuHistory: cpuHistory, memHistory: memoryHistory,
            memLevel: pressure.level, memUsedGB: memory.usedGB, memTotalGB: memory.totalGB,
            memCompressedGB: memory.compressedGB, swapUsedGB: latestSwap?.usedGB ?? 0,
            swapAllocatedGB: latestSwap?.totalGB ?? 0, diskFraction: latestDisk?.usedFraction ?? 0,
            diskUsedGB: latestDisk?.usedGB ?? 0, diskTotalGB: latestDisk?.totalGB ?? 0,
            diskPurgeableGB: latestDisk?.purgeableGB ?? 0))
    }
}
