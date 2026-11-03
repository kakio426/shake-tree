import Darwin
import Foundation

enum LidAwakeStatus: Equatable {
    case off, preparing, active, external, stopping, failed(String)
}
struct LidAwakePaths: Sendable { let state: URL; let script: URL }

/// A sleeping child owns the system-wide override only for this session. Its stdin
/// closes on an app crash; a login agent also recovers an orphaned lease after reboot.
@MainActor
final class LidAwakeController {
    private(set) var status: LidAwakeStatus = .off { didSet { if status != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    var onExpired: (() -> Void)?
    private var desired = false
    private var deadline: Date?
    private var generation = 0
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = ""
    private var lastFailure: String?
    private let home: URL
    private let sourceScript: URL?
    private let setup: @Sendable (URL, URL?) throws -> LidAwakePaths
    private let recover: @Sendable (URL) -> Int32
    private let environment: [String: String]?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         sourceScript: URL? = Bundle.main.url(forResource: "lid-awake-guard", withExtension: "sh"),
         setup: @escaping @Sendable (URL, URL?) throws -> LidAwakePaths = { try LidAwakeSetup.prepare(home: $0, sourceScript: $1) },
         recover: @escaping @Sendable (URL) -> Int32 = { LidAwakeSetup.recoverIfPresent(home: $0) },
         environment: [String: String]? = nil) {
        self.home = home
        self.sourceScript = sourceScript
        self.setup = setup
        self.recover = recover
        self.environment = environment
    }

    func configure(enabled: Bool, endsAt: Date?) {
        if !enabled {
            let wasDesired = desired
            desired = false
            deadline = nil
            if let input {
                self.input = nil
                status = .stopping
                send("STOP", to: input)
                try? input.fileHandleForWriting.close()
            } else if process == nil {
                generation += 1
                if wasDesired {
                    status = .off
                    recoverIfNeeded()
                } else if case .failed = status {} else { status = .off }
            }
            return
        }
        if desired {
            if deadline != endsAt {
                deadline = endsAt
                if let input { send("DEADLINE \(Self.epoch(endsAt))", to: input) }
            }
            return
        }
        desired = true
        deadline = endsAt
        if process == nil { start() }
    }

    func recheckAfterPowerChange() {
        if desired, let input { send("CHECK", to: input) }
    }

    /// Check an orphaned lease even when no new session is requested.
    func recoverIfNeeded() {
        guard !desired, process == nil else { return }
        let home = home
        let recover = recover
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { recover(home) }.value
            guard let self, !self.desired, self.process == nil, result != 0, result != 3 else { return }
            self.status = .failed("이전 덮개 닫힘 유지 설정을 복구하지 못했습니다")
        }
    }

    private func start() {
        guard desired, process == nil else { return }
        generation += 1
        let current = generation
        let home = home
        let sourceScript = sourceScript
        let setup = setup
        lastFailure = nil
        status = .preparing
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try setup(home, sourceScript) }
            }.value
            guard let self, self.generation == current, self.desired else { return }
            switch result {
            case let .success(paths): self.launch(paths, generation: current)
            case let .failure(error): self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func launch(_ paths: LidAwakePaths, generation current: Int) {
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [paths.script.path, "watch", paths.state.path, String(Self.epoch(deadline))]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        if let environment { child.environment = environment }
        let writeFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let fdFlags = fcntl(writeFD, F_GETFD)
        if fdFlags >= 0 { _ = fcntl(writeFD, F_SETFD, fdFlags | FD_CLOEXEC) }
        outputBuffer = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.received(data, generation: current) }
        }
        child.terminationHandler = { [weak self] child in
            let exitCode = child.terminationStatus
            Task { @MainActor [weak self] in self?.terminated(exitCode, generation: current) }
        }
        do {
            try child.run()
            self.process = child
            self.input = input
            self.output = output
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            status = .failed("덮개 닫힘 유지를 시작하지 못했습니다")
        }
    }

    private func received(_ data: Data, generation current: Int) {
        guard current == generation else { return }
        outputBuffer += String(decoding: data, as: UTF8.self)
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            switch line {
            case "READY owned": if desired { status = .active }
            case "READY external": if desired { status = .external }
            case let text where text.hasPrefix("ERROR "):
                lastFailure = Self.message(for: String(text.dropFirst(6)))
                status = .failed(lastFailure!)
            default: break
            }
        }
    }

    private func terminated(_ code: Int32, generation current: Int) {
        guard current == generation else { return }
        let restart = desired && status == .stopping && lastFailure == nil && code == 0
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        process = nil
        if desired, code == 0, lastFailure == nil, let deadline, deadline <= Date() {
            onExpired?()
            if !desired { status = .off; return }
        }
        if restart {
            status = .off
            start()
            return
        }
        if let lastFailure { status = .failed(lastFailure) }
        else if desired { status = .failed("덮개 닫힘 유지가 중단됐습니다") }
        else if code == 0 { status = .off }
        else { status = .failed("덮개 닫힘 유지 해제를 확인하지 못했습니다") }
        let home = home
        let recover = recover
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { recover(home) }.value
            guard let self, result != 0, result != 3 else { return }
            self.status = .failed("덮개 닫힘 유지 설정을 복구하지 못했습니다")
        }
    }

    private func send(_ command: String, to pipe: Pipe) {
        try? pipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }
    private static func epoch(_ date: Date?) -> Int64 {
        date.map { Int64(ceil($0.timeIntervalSince1970)) } ?? 0
    }
    private static func message(for code: String) -> String {
        switch code {
        case "authorization": return "덮개 닫힘 유지를 위한 관리자 권한 설정이 필요합니다"
        case "restore": return "덮개 닫힘 유지 해제에 실패했습니다. 전원 설정을 확인해 주세요"
        case "busy": return "이전 덮개 닫힘 유지 세션이 아직 종료되지 않았습니다"
        default: return "덮개 닫힘 유지를 적용하지 못했습니다 (\(code))"
        }
    }
}

private enum LidAwakeSetup {
    private static let label = "dev.yubyeongju.shaketree.lid-recovery"

    static func prepare(home: URL, sourceScript: URL?) throws -> LidAwakePaths {
        guard let sourceScript else { throw Failure("덮개 닫힘 유지 파일을 찾을 수 없습니다") }
        let manager = FileManager.default
        let state = home.appendingPathComponent("Library/Application Support/Shake Tree/LidAwake", isDirectory: true)
        let script = state.appendingPathComponent("lid-awake-guard.sh")
        try manager.createDirectory(at: state, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: state.appendingPathComponent("lease").path) {
            guard manager.fileExists(atPath: script.path) else { throw Failure("이전 덮개 닫힘 세션을 복구할 수 없습니다") }
            var result: Int32 = 3
            for _ in 0..<10 {
                result = try run("/bin/bash", [script.path, "recover", state.path])
                if result != 3 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard result == 0 else { throw Failure("이전 덮개 닫힘 세션을 해제하지 못했습니다") }
        }
        let data = try Data(contentsOf: sourceScript)
        if (try? Data(contentsOf: script)) != data { try data.write(to: script, options: .atomic) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let probe = try run("/bin/bash", [script.path, "probe", state.path])
        if probe == 4 { throw Failure("덮개 닫힘 유지를 위한 관리자 권한 설정이 필요합니다") }
        guard probe == 0 else { throw Failure("시스템 전원 설정을 확인하지 못했습니다") }

        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try manager.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent(label + ".plist")
        let arguments = ["/bin/bash", script.path, "recover", state.path]
        let definition: [String: Any] = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true]
        var createdPlist = false
        if manager.fileExists(atPath: plist.path) {
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            guard current?["Label"] as? String == label, current?["ProgramArguments"] as? [String] == arguments else {
                throw Failure("덮개 닫힘 복구 항목이 다른 설정과 충돌합니다")
            }
        } else {
            let plistData = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            try plistData.write(to: plist, options: .atomic)
            createdPlist = true
        }
        let domain = "gui/\(getuid())"
        if (try? run("/bin/launchctl", ["print", domain + "/" + label])) != 0 {
            guard try run("/bin/launchctl", ["bootstrap", domain, plist.path]) == 0 else {
                if createdPlist { try? manager.removeItem(at: plist) }
                throw Failure("덮개 닫힘 복구 항목을 등록하지 못했습니다")
            }
        }
        return LidAwakePaths(state: state, script: script)
    }

    static func recoverIfPresent(home: URL) -> Int32 {
        let state = home.appendingPathComponent("Library/Application Support/Shake Tree/LidAwake", isDirectory: true)
        let script = state.appendingPathComponent("lid-awake-guard.sh")
        guard FileManager.default.fileExists(atPath: state.appendingPathComponent("lease").path) else { return 0 }
        guard FileManager.default.fileExists(atPath: script.path) else { return 1 }
        return (try? run("/bin/bash", [script.path, "recover", state.path])) ?? 1
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
