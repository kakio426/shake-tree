import Foundation
import IOKit.pwr_mgt

/// Amphetamine처럼 맥이 잠들지 않게 유지한다 (디스플레이+시스템 유휴 잠자기 방지).
/// IOKit 전원 assertion 사용. 지속 시간을 주면 그 뒤 자동 해제.
@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var isActive = false
    private(set) var endsAt: Date?

    /// 상태가 바뀔 때(수동 토글 또는 시간 만료) 호출 — 메뉴 갱신용
    var onChange: (() -> Void)?

    /// duration == nil 이면 무기한
    func enable(duration: TimeInterval? = nil) {
        releaseAssertion()

        var id: IOPMAssertionID = 0
        let reason = "Shake Tree — 잠들지 않기" as CFString
        // 디스플레이 유휴 잠자기 방지 → 화면도 계속 켜짐 (Amphetamine 기본 동작)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &id)
        guard result == kIOReturnSuccess else { return }

        assertionID = id
        isActive = true

        if let duration {
            endsAt = Date().addingTimeInterval(duration)
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.disable()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            endsAt = nil
        }
        onChange?()
    }

    func disable() {
        releaseAssertion()
        onChange?()
    }

    func toggle() {
        if isActive { disable() } else { enable() }
    }

    private func releaseAssertion() {
        timer?.invalidate()
        timer = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
        endsAt = nil
    }
}
