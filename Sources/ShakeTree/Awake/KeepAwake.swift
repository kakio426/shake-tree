import Foundation
import IOKit.pwr_mgt

/// Both modes use native idle-sleep assertions, with no polling/caffeinate child.
enum AwakeMode: String, CaseIterable, Identifiable, Sendable {
    case systemOnly, displayOn
    var id: String { rawValue }
    var title: String { self == .systemOnly ? "화면 자동 꺼짐 허용" : "화면 켜짐 유지" }
    var assertionType: CFString {
        self == .systemOnly ? kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
            : kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
    }
}

@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private let defaults: UserDefaults?
    private let assertions: AwakeAssertionClient
    private let now: () -> Date
    private var power = PowerSnapshot()
    private var settings = ResourceSettings()
    private var recordedAt: Date?
    private(set) var lastNotice: String?
    private(set) var isActive = false
    private(set) var endsAt: Date?
    private(set) var sessionDuration: TimeInterval?
    private(set) var mode: AwakeMode
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    init(defaults: UserDefaults? = .standard, assertions: AwakeAssertionClient = .live,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.assertions = assertions
        self.now = now
        // The original label did not distinguish idle display sleep from closing the lid.
        // Existing installations get the intended visible-screen default once; subsequent
        // explicit choices remain intact.
        if defaults?.bool(forKey: "awakeDisplayBehaviorV2") == true {
            self.mode = AwakeMode(rawValue: defaults?.string(forKey: "awakeMode") ?? "") ?? .displayOn
        } else {
            self.mode = .displayOn
            defaults?.set(AwakeMode.displayOn.rawValue, forKey: "awakeMode")
            defaults?.set(true, forKey: "awakeDisplayBehaviorV2")
        }
    }

    @discardableResult
    func enable(duration: TimeInterval? = nil) -> Bool {
        if let duration, !duration.isFinite || duration <= 0 || duration > 86400 {
            lastError = "1분~24시간 범위로 지정해 주세요"
            onChange?()
            return false
        }
        guard !settings.lowBatteryProtection || !power.batteryIsLow else {
            lastError = "배터리 20% 이하에서는 잠자기 방지를 시작하지 않습니다"
            onChange?()
            return false
        }
        guard !power.thermalCritical else {
            lastError = "기기 온도가 너무 높아 잠자기 방지를 시작하지 않습니다"
            onChange?()
            return false
        }
        guard replaceAssertion(mode: mode, duration: duration) else { return false }
        lastNotice = nil
        recordedAt = now()
        sessionDuration = duration
        endsAt = duration.map { now().addingTimeInterval($0) }
        scheduleExpiration()
        recordSession()
        onChange?()
        return true
    }

    func setMode(_ next: AwakeMode) {
        guard next != mode else { return }
        if isActive {
            let remaining = endsAt.map { $0.timeIntervalSince(now()) }
            if let remaining, remaining <= 0 { disable() }
            else if !replaceAssertion(mode: next, duration: remaining) { return }
        }
        mode = next
        defaults?.set(next.rawValue, forKey: "awakeMode")
        lastError = nil
        onChange?()
    }

    func disable(notice: String? = nil) {
        timer?.invalidate()
        timer = nil
        if isActive { assertions.release(assertionID) }
        assertionID = 0
        isActive = false
        endsAt = nil
        sessionDuration = nil
        recordedAt = nil
        lastNotice = notice
        lastError = nil
        recordSession()
        onChange?()
    }
    func toggle() {
        if isActive { disable() } else { enable() }
    }

    func reconcileAfterWake() {
        if isActive, let endsAt, endsAt <= now() {
            disable(notice: "설정한 시간이 끝나 잠자기 방지를 종료했습니다")
        }
    }

    func configure(power: PowerSnapshot, settings: ResourceSettings) {
        self.power = power
        self.settings = settings
        if isActive && settings.lowBatteryProtection && power.batteryIsLow {
            disable(notice: "배터리 20% 이하로 잠자기 방지를 종료했습니다")
        } else if isActive && power.thermalCritical {
            disable(notice: "기기 온도가 너무 높아 잠자기 방지를 종료했습니다")
        }
    }

    /// Normal quit clears the record. A crash leaves it for recovery on the next launch.
    /// Only sessions started in the last 24 hours are eligible; expired/legacy records stay off.
    func restoreAfterInterruption() {
        guard let defaults, defaults.bool(forKey: "awakeSessionActive") else { return }
        let stamp = defaults.double(forKey: "awakeSessionRecordedAt")
        let age = now().timeIntervalSince1970 - stamp
        let end = defaults.double(forKey: "awakeSessionEndsAt")
        guard settings.restoreInterruptedAwake, stamp > 0, age >= -60, age <= 86400,
              end == 0 || end > now().timeIntervalSince1970 else {
            disable(notice: "이전 세션은 만료되었거나 복원 대상이 아닙니다")
            return
        }
        let originalDuration = defaults.double(forKey: "awakeSessionDuration")
        guard enable(duration: end > 0 ? end - now().timeIntervalSince1970 : nil) else {
            defaults.set(false, forKey: "awakeSessionActive")
            return
        }
        recordedAt = Date(timeIntervalSince1970: stamp)
        sessionDuration = originalDuration > 0 ? originalDuration : nil
        lastNotice = "중단된 잠자기 방지 세션을 복원했습니다"
        recordSession()
        onChange?()
    }

    private func replaceAssertion(mode: AwakeMode, duration: TimeInterval?) -> Bool {
        let (result, next) = assertions.create(mode, duration)
        guard result == kIOReturnSuccess else {
            lastError = "잠자기 방지를 시작할 수 없음 (\(result))"
            onChange?()
            return false
        }
        // Failed mode changes must never discard the still-valid old assertion.
        if isActive { assertions.release(assertionID) }
        assertionID = next
        isActive = true
        lastError = nil
        return true
    }
    private func scheduleExpiration() {
        timer?.invalidate()
        timer = nil
        guard let endsAt else { return }
        let remaining = max(0.01, endsAt.timeIntervalSince(now()))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.disable(notice: "설정한 시간이 끝나 잠자기 방지를 종료했습니다") }
        }
        timer.tolerance = min(0.25, remaining * 0.001)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func recordSession() {
        defaults?.set(isActive, forKey: "awakeSessionActive")
        defaults?.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: "awakeSessionEndsAt")
        defaults?.set(recordedAt?.timeIntervalSince1970 ?? 0, forKey: "awakeSessionRecordedAt")
        defaults?.set(sessionDuration ?? 0, forKey: "awakeSessionDuration")
    }
    var assertionTypeForDiagnostics: String? {
        isActive ? assertions.type(assertionID) : nil
    }
}
