import Foundation
import IOKit.ps

/// Initial read plus power/thermal notifications; no battery polling timer.
@MainActor
final class PowerMonitor {
    private(set) var snapshot = PowerSnapshot()
    var onChange: ((PowerSnapshot) -> Void)?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard source == nil, observers.isEmpty else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().read()
            }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            })
        }
        read()
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    private func read() {
        var next = PowerSnapshot(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                 thermalLimited: ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSIsPresentKey] as? Bool != false,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                next.batteryPercent = min(100, max(0, current * 100 / maximum))
                next.onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
                break
            }
        }
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }
}
