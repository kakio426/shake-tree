import Foundation

/// Swap has two different quantities: pages currently used (vm.swapusage used),
/// and files already allocated on disk (vm.swapusage total). Subtract only the
/// latter from physical occupied storage. Purgeable space stays inside occupied.
struct StorageBreakdown: Equatable, Sendable {
    let totalGB: Double
    let occupiedGB: Double
    let swapAllocatedGB: Double
    let purgeableGB: Double
    var swapGB: Double { min(max(0, swapAllocatedGB), max(0, occupiedGB)) }
    var fileSystemGB: Double { max(0, occupiedGB - swapGB) }
    var reclaimableGB: Double { min(max(0, purgeableGB), fileSystemGB) }
    var ordinaryFraction: Double { fraction(fileSystemGB - reclaimableGB) }
    var swapFraction: Double { fraction(swapGB) }
    var purgeableFraction: Double { fraction(reclaimableGB) }
    var freeGB: Double { max(0, totalGB - occupiedGB) }
    private func fraction(_ value: Double) -> Double {
        totalGB > 0 ? min(1, max(0, value / totalGB)) : 0
    }
}
