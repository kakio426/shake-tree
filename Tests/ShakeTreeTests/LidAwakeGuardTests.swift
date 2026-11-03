import Darwin
import Foundation
import XCTest
@testable import ShakeTree

@MainActor
final class LidAwakeGuardTests: XCTestCase {
    func testClosingControlPipeRestoresOwnedFlag() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let child = try harness.start()
        XCTAssertEqual(try harness.readLine(child), "READY owned")
        XCTAssertEqual(try harness.flag(), "1")
        try child.input.fileHandleForWriting.close()
        try harness.wait(child)
        XCTAssertEqual(try harness.flag(), "0")
        XCTAssertFalse(harness.hasLease)
    }

    func testExistingSystemOverrideIsNotRemoved() throws {
        let harness = try GuardHarness(initialFlag: "1")
        defer { harness.cleanUp() }
        let child = try harness.start()
        XCTAssertEqual(try harness.readLine(child), "READY external")
        try child.input.fileHandleForWriting.close()
        try harness.wait(child)
        XCTAssertEqual(try harness.flag(), "1")
        XCTAssertFalse(harness.hasLease)
    }

    func testCrashRecoveryAndLiveLeaseExclusion() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let child = try harness.start()
        XCTAssertEqual(try harness.readLine(child), "READY owned")
        XCTAssertEqual(try harness.recover(), 3)
        XCTAssertEqual(try harness.flag(), "1")
        XCTAssertEqual(Darwin.kill(child.process.processIdentifier, SIGKILL), 0)
        try harness.wait(child)
        XCTAssertTrue(harness.hasLease)
        XCTAssertEqual(try harness.recover(), 0)
        XCTAssertEqual(try harness.flag(), "0")
        XCTAssertFalse(harness.hasLease)
    }

    func testSecondGuardCannotTakeOverAnActiveLease() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let first = try harness.start()
        XCTAssertEqual(try harness.readLine(first), "READY owned")
        let second = try harness.start()
        XCTAssertEqual(try harness.readLine(second), "ERROR busy")
        try harness.wait(second)
        XCTAssertEqual(try harness.flag(), "1")
        try first.input.fileHandleForWriting.close()
        try harness.wait(first)
        XCTAssertEqual(try harness.flag(), "0")
    }

    func testDeadlineAndPowerChangeRecheck() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let child = try harness.start(deadline: Int(Date().timeIntervalSince1970) + 3)
        XCTAssertEqual(try harness.readLine(child), "READY owned")
        try harness.setFlag("0") // Simulates the system dropping the override on a power transition.
        try child.input.fileHandleForWriting.write(contentsOf: Data("CHECK\n".utf8))
        XCTAssertEqual(try harness.readLine(child), "READY owned")
        XCTAssertEqual(try harness.flag(), "1")
        try harness.wait(child, timeout: 6)
        XCTAssertEqual(try harness.flag(), "0")
        XCTAssertFalse(harness.hasLease)
    }

    func testMissingAuthorizationLeavesPowerSettingUntouched() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        try Data().write(to: harness.directory.appendingPathComponent("unauthorized"))
        let child = try harness.start()
        XCTAssertEqual(try harness.readLine(child), "ERROR authorization")
        try harness.wait(child)
        XCTAssertNotEqual(child.process.terminationStatus, 0)
        XCTAssertEqual(try harness.flag(), "0")
        XCTAssertFalse(harness.hasLease)
    }

    func testFailedRestoreKeepsRecoveryRecord() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let child = try harness.start()
        XCTAssertEqual(try harness.readLine(child), "READY owned")
        let fail = harness.directory.appendingPathComponent("fail-restore")
        try Data().write(to: fail)
        try child.input.fileHandleForWriting.close()
        XCTAssertEqual(try harness.readLine(child), "ERROR restore")
        try harness.wait(child)
        XCTAssertTrue(harness.hasLease)
        try FileManager.default.removeItem(at: fail)
        XCTAssertEqual(try harness.recover(), 0)
        XCTAssertEqual(try harness.flag(), "0")
        XCTAssertFalse(harness.hasLease)
    }

    func testControllerRearmsAfterRapidOffAndOn() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let paths = LidAwakePaths(state: harness.directory, script: harness.script)
        let controller = LidAwakeController(home: harness.directory, sourceScript: harness.script,
            setup: { _, _ in paths }, environment: harness.environment)
        controller.configure(enabled: true, endsAt: nil)
        XCTAssertTrue(waitUntil { controller.status == .active })
        controller.configure(enabled: false, endsAt: nil)
        controller.configure(enabled: true, endsAt: nil)
        XCTAssertTrue(waitUntil { controller.status == .active })
        XCTAssertEqual(try harness.flag(), "1")
        controller.configure(enabled: false, endsAt: nil)
        XCTAssertTrue(waitUntil { controller.status == .off })
        XCTAssertEqual(try harness.flag(), "0")
    }

    func testControllerReportsExpiryAndReleasesFlag() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let paths = LidAwakePaths(state: harness.directory, script: harness.script)
        let controller = LidAwakeController(home: harness.directory, sourceScript: harness.script,
            setup: { _, _ in paths }, environment: harness.environment)
        var expired = false
        controller.onExpired = { expired = true; controller.configure(enabled: false, endsAt: nil) }
        controller.configure(enabled: true, endsAt: Date().addingTimeInterval(1))
        XCTAssertTrue(waitUntil { controller.status == .active })
        XCTAssertTrue(waitUntil(timeout: 5) { expired && controller.status == .off })
        XCTAssertEqual(try harness.flag(), "0")
        controller.onExpired = nil
    }

    func testControllerRecoversWhenItsGuardCrashes() throws {
        let harness = try GuardHarness(initialFlag: "0")
        defer { harness.cleanUp() }
        let paths = LidAwakePaths(state: harness.directory, script: harness.script)
        let environment = harness.environment
        let controller = LidAwakeController(home: harness.directory, sourceScript: harness.script,
            setup: { _, _ in paths }, recover: { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [paths.script.path, "recover", paths.state.path]
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
                catch { return 1 }
            }, environment: environment)
        controller.configure(enabled: true, endsAt: nil)
        XCTAssertTrue(waitUntil { controller.status == .active })
        let ownerFile = harness.directory.appendingPathComponent("lease/owner")
        let owner = try Int32(String(contentsOf: ownerFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(owner)
        XCTAssertEqual(Darwin.kill(try XCTUnwrap(owner), SIGKILL), 0)
        XCTAssertTrue(waitUntil { (try? harness.flag()) == "0" && !harness.hasLease })
        if case .failed = controller.status {} else { XCTFail("A crashed guard must be reported") }
        controller.configure(enabled: false, endsAt: nil)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}

@MainActor
private final class GuardHarness {
    struct Child { let process: Process; let input: Pipe; let output: Pipe }
    let directory: URL
    let script: URL
    private let backend: URL
    private var children: [Child] = []

    init(initialFlag: String) throws {
        let root = ProcessInfo.processInfo.environment["SHAKETREE_QA_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        directory = root.appendingPathComponent("lid-guard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/lid-awake-guard.sh")
        backend = directory.appendingPathComponent("backend.sh")
        let source = """
        #!/bin/bash
        case "$1" in
          boot) echo test-boot ;;
          read) /bin/cat "$MOCK_DIR/flag" ;;
          authorized) [[ ! -e "$MOCK_DIR/unauthorized" ]] ;;
          set) [[ "$2" != 0 || ! -e "$MOCK_DIR/fail-restore" ]] || exit 1
               printf '%s\\n' "$2" > "$MOCK_DIR/flag" ;;
        esac
        """
        try source.write(to: backend, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backend.path)
        try setFlag(initialFlag)
    }

    var hasLease: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("lease").path) }
    var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "SHAKETREE_LID_TEST_BACKEND": backend.path, "MOCK_DIR": directory.path,
        ]) { _, new in new }
    }
    func flag() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("flag"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func setFlag(_ value: String) throws {
        try (value + "\n").write(to: directory.appendingPathComponent("flag"), atomically: true, encoding: .utf8)
    }
    func start(deadline: Int = 0) throws -> Child {
        let process = makeProcess([script.path, "watch", directory.path, String(deadline)])
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let child = Child(process: process, input: input, output: output)
        children.append(child)
        return child
    }
    func recover() throws -> Int32 {
        let process = makeProcess([script.path, "recover", directory.path])
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    func readLine(_ child: Child) throws -> String {
        let fd = child.output.fileHandleForReading.fileDescriptor
        var bytes: [UInt8] = []
        while bytes.count < 4096 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard Darwin.poll(&descriptor, 1, 5000) > 0 else { throw Failure.timeout }
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw Failure.eof }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw Failure.timeout
    }
    func wait(_ child: Child, timeout: TimeInterval = 5) throws {
        let end = Date().addingTimeInterval(timeout)
        while child.process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        guard !child.process.isRunning else { throw Failure.timeout }
        child.process.waitUntilExit()
    }
    func cleanUp() {
        for child in children where child.process.isRunning {
            try? child.input.fileHandleForWriting.close()
            try? wait(child)
            if child.process.isRunning { child.process.terminate() }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        return process
    }
    private enum Failure: Error { case timeout, eof }
}
