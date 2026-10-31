import Darwin
import Foundation

/// Bounded reads prevent an inherited stdout pipe from blocking refresh forever.
/// Only the owned Process instance is signalled on cancellation or timeout.
enum UsageProcess {
    struct Output: Sendable { let data: Data; let exitCode: Int32 }
    enum Failure: Error {
        case timeout, tooMuchOutput, launch
        var safeMessage: String {
            switch self {
            case .timeout: "조회 시간 초과 · 다시 시도"
            case .tooMuchOutput: "사용량 응답이 너무 큼"
            case .launch: "조회기를 실행할 수 없음"
            }
        }
    }
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ["\(home)/.gemini/bin", "\(home)/.local/bin", "\(home)/.volta/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (directories + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        if environment["ANTIGRAVITY_CLI_PATH"] == nil {
            environment["ANTIGRAVITY_CLI_PATH"] = ["\(home)/.gemini/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        return environment
    }
    static func run(cli: String, args: [String], timeout: TimeInterval) async throws -> Output {
        let limiter = UsageProcessLimiter.shared
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let job = UsageProcessJob(cli: cli, args: args, timeout: timeout)
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { job.start($0) }
            } onCancel: { job.cancel() }
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }
}
