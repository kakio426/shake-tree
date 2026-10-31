import Foundation

/// The limit covers cancelled-but-still-exiting helpers as well as a new refresh round.
actor UsageProcessLimiter {
    static let shared = UsageProcessLimiter()
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
