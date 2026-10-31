import Foundation
import XCTest
@testable import ShakeTree

@MainActor
final class StorageAndAwakeTests: XCTestCase {
    func testSwapAllocatedBytesAreSeparatedWithoutCountingPurgeableTwice() {
        let storage = StorageBreakdown(totalGB: 500, occupiedGB: 480, swapAllocatedGB: 12, purgeableGB: 3)
        XCTAssertEqual(storage.fileSystemGB, 468)
        XCTAssertEqual(storage.swapGB, 12)
        XCTAssertEqual(storage.freeGB, 20)
        XCTAssertEqual(storage.fileSystemGB + storage.swapGB + storage.freeGB, 500)
        XCTAssertEqual(storage.ordinaryFraction + storage.swapFraction + storage.purgeableFraction, 480 / 500.0, accuracy: 0.000001)
    }
    func testStorageBreakdownDoesNotBecomeNegative() {
        let storage = StorageBreakdown(totalGB: 10, occupiedGB: 4, swapAllocatedGB: 6, purgeableGB: 8)
        XCTAssertEqual(storage.swapGB, 4)
        XCTAssertEqual(storage.fileSystemGB, 0)
        XCTAssertEqual(storage.purgeableFraction, 0)
        XCTAssertEqual(StorageBreakdown(totalGB: 0, occupiedGB: 0, swapAllocatedGB: 0, purgeableGB: 0).ordinaryFraction, 0)
    }
    func testNativeAwakeModesUseDifferentOSAssertionsAndPreserveDeadline() throws {
        let awake = KeepAwake(defaults: nil)
        defer { awake.disable() }
        XCTAssertTrue(awake.enable(duration: 60))
        XCTAssertEqual(awake.assertionTypeForDiagnostics, "PreventUserIdleSystemSleep")
        let end = awake.endsAt
        awake.setMode(.displayOn)
        XCTAssertEqual(awake.assertionTypeForDiagnostics, "PreventUserIdleDisplaySleep")
        XCTAssertEqual(awake.endsAt, end)
        XCTAssertEqual(awake.sessionDuration, 60)
        awake.disable()
        XCTAssertFalse(awake.isActive)
        XCTAssertNil(awake.assertionTypeForDiagnostics)
    }
    func testTimedSessionExpiresAndInvalidDurationKeepsCurrentSession() {
        let awake = KeepAwake(defaults: nil)
        defer { awake.disable() }
        XCTAssertTrue(awake.enable(duration: 0.12))
        let end = awake.endsAt
        XCTAssertFalse(awake.enable(duration: -1))
        XCTAssertTrue(awake.isActive)
        XCTAssertEqual(awake.endsAt, end)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(awake.isActive)
        XCTAssertNil(awake.endsAt)
    }
    func testCustomMinutesRejectOverflowAndOutOfRangeWithoutStarting() {
        let awake = KeepAwake(defaults: nil)
        let model = AppModel(keepAwake: awake)
        model.enableAwake(minutes: Int.max)
        XCTAssertFalse(awake.isActive)
        XCTAssertNotNil(awake.lastError)
    }
}
