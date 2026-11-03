import Foundation

struct ResourceSettings: Equatable, Sendable {
    var economy = true
    var systemEnabled = true
    var clipboardEnabled = true
    var usageEnabled = true
    var animationEnabled = true
    var lowBatteryProtection = true
    var restoreInterruptedAwake = true
    var lidAwakeEnabled = true

    init(defaults: UserDefaults? = nil) {
        guard let defaults else { return }
        for (keyPath, key) in Self.keys {
            if defaults.object(forKey: key) != nil { self[keyPath: keyPath] = defaults.bool(forKey: key) }
        }
    }
    private static var keys: [WritableKeyPath<Self, Bool>: String] { [
        \.economy: "resourceEconomy", \.systemEnabled: "systemMonitoringEnabled",
        \.clipboardEnabled: "clipboardMonitoringEnabled", \.usageEnabled: "usageMonitoringEnabled",
        \.animationEnabled: "treeAnimationEnabled", \.lowBatteryProtection: "awakeLowBatteryProtection",
        \.restoreInterruptedAwake: "restoreInterruptedAwake", \.lidAwakeEnabled: "awakeLidEnabled",
    ] }
    func save(to defaults: UserDefaults) {
        for (path, key) in Self.keys { defaults.set(self[keyPath: path], forKey: key) }
    }
}

struct PowerSnapshot: Equatable, Sendable {
    var onBattery = false
    var batteryPercent: Int?
    var lowPower = false
    var thermalLimited = false
    var thermalCritical = false
    var batteryIsLow: Bool { onBattery && batteryPercent.map { $0 <= 20 } == true }
}

struct ResourcePolicy: Equatable, Sendable {
    let sampleInterval: TimeInterval?
    let memoryInterval: TimeInterval
    let animationEnabled: Bool
    let frameRate: Float

    init(settings: ResourceSettings, power: PowerSnapshot, visible: Bool, suspended: Bool) {
        let constrained = power.lowPower || power.thermalLimited
        let economy = settings.economy || power.onBattery || constrained
        sampleInterval = !settings.systemEnabled || suspended ? nil
            : constrained ? (visible ? 5 : 10) : economy ? (visible ? 2 : 5) : (visible ? 1 : 3)
        memoryInterval = visible ? (sampleInterval ?? 2) : economy ? 10 : 5
        animationEnabled = settings.animationEnabled && settings.systemEnabled && !suspended && !constrained
        frameRate = economy ? 5 : 12
    }
}
