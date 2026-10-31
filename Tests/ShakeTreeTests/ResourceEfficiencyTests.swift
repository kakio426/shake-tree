import AppKit
import Combine
import Darwin
import IOKit.pwr_mgt
import SwiftUI
import XCTest
@testable import ShakeTree

@MainActor
final class ResourceEfficiencyTests: XCTestCase {
    func testSamplingDoesNotAccumulateHostPortReferences() {
        let host = MachHostPort()
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        func refs() -> mach_port_urefs_t {
            var value: mach_port_urefs_t = 0
            XCTAssertEqual(mach_port_get_refs(mach_task_self_, host.name, mach_port_right_t(MACH_PORT_RIGHT_SEND), &value), KERN_SUCCESS)
            return value
        }
        let before = refs()
        for _ in 0..<1000 { _ = cpu.sample(); _ = memory.sample() }
        XCTAssertEqual(refs(), before, "Repeated native measurements must reuse their owned host rights")
    }

    func testPowerPolicySlowsSamplingAndStopsWorkWhenUnavailable() {
        var settings = ResourceSettings()
        XCTAssertEqual(ResourcePolicy(settings: settings, power: .init(), visible: false, suspended: false).sampleInterval, 5)
        XCTAssertEqual(ResourcePolicy(settings: settings, power: .init(), visible: true, suspended: false).sampleInterval, 2)
        let low = ResourcePolicy(settings: settings, power: .init(lowPower: true), visible: false, suspended: false)
        XCTAssertEqual(low.sampleInterval, 10)
        XCTAssertFalse(low.animationEnabled)
        XCTAssertNil(ResourcePolicy(settings: settings, power: .init(), visible: true, suspended: true).sampleInterval)
        settings.systemEnabled = false
        let off = ResourcePolicy(settings: settings, power: .init(), visible: true, suspended: false)
        XCTAssertNil(off.sampleInterval)
        XCTAssertFalse(off.animationEnabled)
        let service = SystemMetricsService()
        service.configure(policy: low, visible: false)
        XCTAssertEqual(service.samplingIntervalForDiagnostics, 10)
        service.configure(policy: off, visible: false)
        XCTAssertNil(service.samplingIntervalForDiagnostics)
        service.stop()
    }

    func testClipboardPollingIsReleasedWhenDisabledOrScreenSleeps() {
        let watcher = ClipboardWatcher()
        watcher.configurePolling(enabled: true, suspended: false)
        XCTAssertTrue(watcher.isPollingForDiagnostics)
        watcher.configurePolling(enabled: true, suspended: true)
        XCTAssertFalse(watcher.isPollingForDiagnostics)
        watcher.configurePolling(enabled: true, suspended: false)
        XCTAssertTrue(watcher.isPollingForDiagnostics)
        watcher.configurePolling(enabled: false, suspended: false)
        XCTAssertFalse(watcher.isPollingForDiagnostics)
    }

    func testSystemUpdatesDoNotInvalidateWholeAppModel() {
        let model = AppModel(keepAwake: KeepAwake(defaults: nil), defaults: nil)
        var invalidations = 0
        let subscription = model.objectWillChange.sink { invalidations += 1 }
        var next = SystemSnapshot.empty
        next.cpuFraction = 0.5
        model.updateSystem(next)
        XCTAssertEqual(model.system.cpuFraction, 0.5)
        XCTAssertEqual(invalidations, 0)
        withExtendedLifetime(subscription) {}
    }

    func testSmallPanelHasScrollableContentWithinAvailableHeight() {
        _ = NSApplication.shared
        let model = AppModel(keepAwake: KeepAwake(defaults: nil), defaults: nil)
        let controller = MainPanelController(model: model, maximumHeight: 180)
        controller.show()
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let host = controller.hostedViewForDiagnostics else { return XCTFail("Missing hosting view") }
        XCTAssertLessThanOrEqual(host.frame.height, 180.5)
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        guard let scroll = findScroll(host), let document = scroll.documentView else { return XCTFail("Missing native scroll container") }
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "The clipped lower controls must be reachable by scrolling")
    }

    func testFailedAssertionReplacementPreservesExistingSession() {
        let fake = FakeAssertions()
        let awake = KeepAwake(defaults: nil, assertions: fake.client)
        XCTAssertTrue(awake.enable(duration: 120))
        let deadline = awake.endsAt
        fake.fail = true
        awake.setMode(.displayOn)
        XCTAssertTrue(awake.isActive)
        XCTAssertEqual(awake.mode, .systemOnly)
        XCTAssertEqual(awake.endsAt, deadline)
        XCTAssertEqual(fake.active.count, 1)
        fake.fail = false
        awake.disable()
        XCTAssertTrue(fake.active.isEmpty)
    }

    func testFullOverviewFitsCompactHeightAndSummaryKeepsQuotaIdentity() throws {
        _ = NSApplication.shared
        let now = Date()
        let weekly = ProviderUsage.WindowDisplay(id: "weekly", label: "1주일", group: "Gemini", usedPercent: 58,
                                                resetsAt: now.addingTimeInterval(86400), resetDescription: nil)
        let expired = ProviderUsage.WindowDisplay(id: "expired", label: "5시간", group: "Claude / GPT", usedPercent: 100,
                                                 resetsAt: now.addingTimeInterval(-1), resetDescription: nil)
        let usages = ["codex", "claude", "antigravity", "grok"].map { provider in
            let current = ProviderUsage.WindowDisplay(id: "weekly", label: "1주일", group: provider == "antigravity" ? "Gemini" : nil,
                usedPercent: weekly.usedPercent, resetsAt: weekly.resetsAt, resetDescription: nil)
            return ProviderUsage(provider: provider, fetchedAt: now, windows: [current, expired])
        }
        XCTAssertEqual(CompactUsageView.summaryWindow(usages[2], at: now)?.id, "weekly")
        var stale = usages[2]
        stale.fetchedAt = now.addingTimeInterval(-7200)
        XCTAssertNil(CompactUsageView.summaryWindow(stale, at: now))
        let previous = try XCTUnwrap(CompactUsageView.summarySnapshot(stale, at: now))
        XCTAssertFalse(previous.isCurrent)
        XCTAssertEqual(previous.window.id, "weekly", "A cached quota should stay visible when clearly marked as previous")
        var failed = usages[2]
        failed.issue = "조회 실패"
        XCTAssertFalse(try XCTUnwrap(CompactUsageView.summarySnapshot(failed, at: now)).isCurrent,
                       "A failed refresh must not make its last successful quota look current")
        let model = AppModel(keepAwake: KeepAwake(defaults: nil), defaults: nil)
        model.updateUsage(usages, statusText: "확인 완료")
        var system = SystemSnapshot.empty
        system.cpuFraction = 0.48
        system.cpuHistory = (0..<30).map { 0.4 + 0.15 * sin(Double($0) * 0.5) }
        system.memUsedGB = 14.2
        system.memTotalGB = 17
        system.memHistory = (0..<30).map { 0.8 + Double($0) / 1000 }
        system.diskTotalGB = 494
        system.diskUsedGB = 480
        system.diskFraction = 480 / 494.0
        system.swapAllocatedGB = 12
        model.updateSystem(system)
        let controller = MainPanelController(model: model)
        controller.show()
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let host = try XCTUnwrap(controller.hostedViewForDiagnostics)
        XCTAssertLessThanOrEqual(host.frame.height, 400, "All four services must fit a short overview, without expanded cards or settings switches")
        if let directory = ProcessInfo.processInfo.environment["SHAKETREE_QA_OUTPUT"] {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-overview.png"))
        }
    }

    func testSettingsWindowReleasesItsHostingTreeWhenClosed() {
        _ = NSApplication.shared
        let controller = UtilityWindowController()
        let model = AppModel(keepAwake: KeepAwake(defaults: nil), defaults: nil)
        weak var host: NSView?
        autoreleasepool {
            controller.show(title: "Shake Tree settings test", size: NSSize(width: 480, height: 560),
                            content: AnyView(SettingsWindowView(model: model, page: .resources)))
            host = controller.hostedViewForDiagnostics
            XCTAssertNotNil(host)
            controller.close()
        }
        for _ in 0..<10 where host != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(host)
    }

    func testLowBatteryReleasesAssertionAndBlocksRestartUntilAllowed() {
        let fake = FakeAssertions()
        let awake = KeepAwake(defaults: nil, assertions: fake.client)
        XCTAssertTrue(awake.enable())
        let low = PowerSnapshot(onBattery: true, batteryPercent: 15)
        awake.configure(power: low, settings: .init())
        XCTAssertFalse(awake.isActive)
        XCTAssertTrue(fake.active.isEmpty)
        XCTAssertNotNil(awake.lastNotice)
        XCTAssertFalse(awake.enable())
        awake.configure(power: .init(onBattery: false, batteryPercent: 15), settings: .init())
        XCTAssertTrue(awake.enable())
        awake.disable()
    }

    func testInterruptedSessionRestoresDeadlineAndNormalQuitKeepsItOff() throws {
        let name = "ShakeTreeTests.awake.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fake = FakeAssertions()
        let first = KeepAwake(defaults: defaults, assertions: fake.client)
        XCTAssertTrue(first.enable(duration: 120))
        first.setMode(.displayOn)
        let deadline = try XCTUnwrap(first.endsAt)
        fake.active.removeAll() // The OS releases assertions when a process crashes.
        let recovered = KeepAwake(defaults: defaults, assertions: fake.client)
        recovered.restoreAfterInterruption()
        XCTAssertTrue(recovered.isActive)
        XCTAssertEqual(recovered.mode, .displayOn)
        XCTAssertEqual(recovered.sessionDuration, 120)
        XCTAssertEqual(try XCTUnwrap(recovered.endsAt).timeIntervalSince(deadline), 0, accuracy: 0.05)
        recovered.disable()
        let next = KeepAwake(defaults: defaults, assertions: fake.client)
        next.restoreAfterInterruption()
        XCTAssertFalse(next.isActive)
        first.disable()
    }

    func testExpiredInterruptedSessionDoesNotAcquireAnAssertion() throws {
        let name = "ShakeTreeTests.expired.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "awakeSessionActive")
        defaults.set(Date().timeIntervalSince1970 - 120, forKey: "awakeSessionRecordedAt")
        defaults.set(Date().timeIntervalSince1970 - 1, forKey: "awakeSessionEndsAt")
        let fake = FakeAssertions()
        let awake = KeepAwake(defaults: defaults, assertions: fake.client)
        awake.restoreAfterInterruption()
        XCTAssertFalse(awake.isActive)
        XCTAssertTrue(fake.active.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "awakeSessionActive"))
    }
}

@MainActor
private final class FakeAssertions {
    var active: [IOPMAssertionID: AwakeMode] = [:]
    var fail = false
    private var next: IOPMAssertionID = 0
    var client: AwakeAssertionClient {
        .init(create: { [self] mode, _ in
            if fail { return (kIOReturnError, 0) }
            next += 1
            active[next] = mode
            return (kIOReturnSuccess, next)
        }, release: { [self] in active.removeValue(forKey: $0) },
              type: { [self] in active[$0].map { $0 == .systemOnly ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep" } })
    }
}
