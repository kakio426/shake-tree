import Darwin
import Foundation

/// All mutable state belongs to this serial queue. Read/exit/deadline events replace polling.
final class UsageProcessJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.yubyeongju.shaketree.usage-process", qos: .utility)
    private let process = Process()
    private let pipe = Pipe()
    private let timeout: TimeInterval
    private var reader: DispatchSourceRead?
    private var deadline: DispatchSourceTimer?
    private var continuation: CheckedContinuation<UsageProcess.Output, any Error>?
    private var data = Data()
    private var cancelled = false
    private var stoppingError: (any Error)?
    private var finished = false

    init(cli: String, args: [String], timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        process.environment = UsageProcess.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }
    func start(_ continuation: CheckedContinuation<UsageProcess.Output, any Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            self.launch()
        }
    }
    func cancel() {
        queue.async {
            self.cancelled = true
            if self.continuation != nil { self.requestStop(CancellationError()) }
        }
    }
    private func launch() {
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
            finish(.failure(UsageProcess.Failure.launch)); return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        let handle = pipe.fileHandleForReading
        source.setCancelHandler { try? handle.close() }
        reader = source
        source.resume()
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.drain()
                if let error = self.stoppingError { self.finish(.failure(error)) }
                else { self.finish(.success(.init(data: self.data, exitCode: self.process.terminationStatus))) }
            }
        }
        do { try process.run() }
        catch { finish(.failure(UsageProcess.Failure.launch)); return }
        try? pipe.fileHandleForWriting.close()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.requestStop(UsageProcess.Failure.timeout) }
        timer.schedule(deadline: .now() + max(0, timeout), leeway: .milliseconds(10))
        deadline = timer
        timer.resume()
    }
    private func drain() {
        guard !finished, stoppingError == nil, reader != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 2 * 1024 * 1024 { requestStop(UsageProcess.Failure.tooMuchOutput); return }
            } else if count == 0 {
                reader?.cancel()
                reader = nil
                return
            } else if errno != EINTR { return }
        }
    }
    private func requestStop(_ error: any Error) {
        guard !finished, stoppingError == nil else { return }
        stoppingError = error
        deadline?.cancel()
        deadline = nil
        if !process.isRunning { finish(.failure(error)); return }
        process.terminate()
        // One delayed escalation, only for the Process we own. No waitUntilExit polling.
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [self] in
            if !finished && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private func finish(_ result: Result<UsageProcess.Output, any Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        if let reader { reader.cancel() }
        else { try? pipe.fileHandleForReading.close() }
        reader = nil
        try? pipe.fileHandleForWriting.close()
        process.terminationHandler = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
