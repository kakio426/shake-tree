import Foundation
import XCTest
@testable import ShakeTree

@MainActor
final class UsageProviderTests: XCTestCase {
    private let now = CodexBarEntry.date("2026-10-30T01:07:39Z")!
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "antigravity-0.82", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func sampleWindow(_ used: Double = 25, placeholder: Bool = false) -> [String: Any] {
        ["usedPercent": used, "windowMinutes": 300, "resetsAt": "2026-10-30T02:50:11.123Z", "isSyntheticPlaceholder": placeholder]
    }
    func testLiveAntigravityFixtureRetainsEveryQuotaAndIdentity() throws {
        let result = UsageProvider.decode(try fixture(), provider: "antigravity", now: now)
        let usage = try XCTUnwrap(result.usage)
        XCTAssertEqual(usage.provider, "antigravity")
        XCTAssertEqual(usage.windows.count, 5, "Primary/secondary duplicates must disappear, model groups must remain")
        XCTAssertEqual(Set(usage.windows.compactMap(\.group)), ["Gemini", "Claude / GPT", "Gemini 4 Argon"])
        XCTAssertEqual(usage.windows.filter { $0.group == "Claude / GPT" }.count, 2)
        XCTAssertEqual(usage.displayGroup("Claude / GPT"), "외부 모델 공유 한도", "Existing cached quota groups must acquire the clearer label without changing their observations")
        XCTAssertEqual(usage.windows.first?.usedPercent ?? -1, 2.198880910873413, accuracy: 0.000001)
        XCTAssertEqual(usage.windows.last?.usedPercent ?? -1, 99.64191999752074, accuracy: 0.000001)
        XCTAssertEqual(usage.fetchedAt, now)
        XCTAssertEqual(usage.source, "cli")
    }
    func testNativeGeminiAndAntigravityRemainIndependent() throws {
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [[String: Any]])
        rows.append(["provider": "gemini", "usage": ["primary": sampleWindow(42)]])
        let payload = try data(rows)
        XCTAssertEqual(UsageProvider.decode(payload, provider: "gemini", now: now).usage?.windows.first?.usedPercent, 42)
        XCTAssertEqual(UsageProvider.decode(payload, provider: "antigravity", now: now).usage?.windows.count, 5)
    }
    func testEmptyNativeGeminiCannotBlockAntigravity() throws {
        let empty = try data([["provider": "gemini", "usage": [:]]])
        XCTAssertNil(UsageProvider.decode(empty, provider: "gemini", now: now).usage)
        XCTAssertNotNil(UsageProvider.decode(try fixture(), provider: "antigravity", now: now).usage)
    }
    func testSyntheticAndInvalidWindowsAreRejectedButMeasuredExtrasRemain() throws {
        let payload = try data([["provider": "gemini", "usage": [
            "primary": sampleWindow(0, placeholder: true), "secondary": sampleWindow(101),
            "extraRateWindows": [["id": "actual", "title": "Measured model", "window": sampleWindow(64)]]]]])
        let usage = try XCTUnwrap(UsageProvider.decode(payload, provider: "gemini", now: now).usage)
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].usedPercent, 64)
        let syntheticOnly = try data([["provider": "gemini", "usage": ["primary": sampleWindow(0, placeholder: true)]]])
        XCTAssertNil(UsageProvider.decode(syntheticOnly, provider: "gemini", now: now).usage)
    }
    func testErrorIsPreservedAndSensitiveDetailsAreNotDisplayed() throws {
        let payload = try data([["provider": "antigravity", "error": ["message": "HTTP 403 https://secret.example/?token=private person@example.com"]]])
        let result = UsageProvider.decode(payload, provider: "antigravity", now: now)
        XCTAssertNil(result.usage)
        XCTAssertEqual(result.issue, "이용 권한 확인 필요 (HTTP 403)")
        XCTAssertFalse(result.issue?.contains("private") ?? true)
    }
    func testMigrationErrorExplainsCorrectProvider() {
        XCTAssertEqual(UsageProvider.safeIssue("Google no longer supports Gemini CLI OAuth for individual accounts. Sign in to Antigravity."), "개인 계정 한도는 Antigravity에서 확인")
    }
    func testLogsAndUnrelatedArraysDoNotHideRealResponse() throws {
        var payload = Data("diagnostic []\n[not json]\n".utf8)
        payload.append(try fixture())
        XCTAssertEqual(UsageProvider.decode(payload, provider: "antigravity", now: now).usage?.windows.count, 5)
    }
    func testPartialSuccessDoesNotRefreshFailedProvidersTimestamp() throws {
        let provider = UsageProvider(cacheURL: nil)
        let oldDate = now.addingTimeInterval(-7200)
        var old = try XCTUnwrap(UsageProvider.decode(fixture(), provider: "antigravity", now: oldDate).usage)
        old.fetchedAt = oldDate
        provider.apply(UsageFetchResult(provider: "antigravity", usage: old))
        provider.apply(UsageFetchResult(provider: "antigravity", issue: "접속 실패"))
        provider.apply(UsageFetchResult(provider: "codex", usage: ProviderUsage(provider: "codex", fetchedAt: now)))
        provider.publish()
        let retained = try XCTUnwrap(provider.usages.first { $0.provider == "antigravity" })
        XCTAssertEqual(retained.fetchedAt, oldDate)
        XCTAssertEqual(retained.issue, "접속 실패")
        XCTAssertTrue(retained.isStale(at: now))
        XCTAssertTrue(retained.freshnessText(at: now).hasPrefix("이전 값"))
        XCTAssertFalse(provider.statusText.hasPrefix("업데이트:"))
        XCTAssertFalse(retained.canShow(retained.windows[0], at: now))
    }
    func testResetAndAgeNeverInventNewAllowance() throws {
        let usage = try XCTUnwrap(UsageProvider.decode(fixture(), provider: "antigravity", now: now).usage)
        let window = usage.windows[0]
        XCTAssertTrue(usage.canShow(window, at: now))
        let afterReset = try XCTUnwrap(window.resetsAt).addingTimeInterval(1)
        XCTAssertFalse(usage.canShow(window, at: afterReset))
        XCTAssertEqual(window.resetText(at: afterReset), "리셋 후 재조회 필요")
        let restored = try JSONDecoder().decode(ProviderUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(restored.windows[0].resetsAt, window.resetsAt)
        XCTAssertEqual(restored.fetchedAt, now)
        XCTAssertEqual(restored.windows[0].resetText(at: afterReset), "리셋 후 재조회 필요")
    }
    func testLegacyCacheDoesNotReattributeGemini() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"savedAt":815011283,"usages":[{"provider":"gemini","windows":[],"sparkWindows":[]}]}"#.utf8).write(to: url)
        let provider = UsageProvider(cacheURL: url)
        XCTAssertTrue(provider.usages.allSatisfy { $0.fetchedAt == nil })
    }
    func testProcessTimeoutIsBounded() async throws {
        let start = Date()
        do {
            _ = try await UsageProcess.run(cli: "/bin/sleep", args: ["5"], timeout: 0.15)
            XCTFail("sleep should time out")
        } catch let failure as UsageProcess.Failure {
            XCTAssertEqual(failure.safeMessage, "조회 시간 초과 · 다시 시도")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testEventDrivenProcessDrainsFullOutputBeforeReturning() async throws {
        let result = try await UsageProcess.run(cli: "/usr/bin/head", args: ["-c", "1048576", "/dev/zero"], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.data.count, 1048576)
        XCTAssertTrue(result.data.allSatisfy { $0 == 0 })
    }
    func testExcessiveOutputTerminatesTheOwnedHelper() async throws {
        do {
            _ = try await UsageProcess.run(cli: "/usr/bin/yes", args: [], timeout: 3)
            XCTFail("Unbounded output must be rejected")
        } catch let failure as UsageProcess.Failure {
            XCTAssertEqual(failure.safeMessage, "사용량 응답이 너무 큼")
        }
    }
    func testCancellationWhileWaitingForGlobalHelperSlotIsPrompt() async throws {
        let first = Task { try await UsageProcess.run(cli: "/bin/sleep", args: ["5"], timeout: 10) }
        let second = Task { try await UsageProcess.run(cli: "/bin/sleep", args: ["5"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(120))
        let waiting = Task { try await UsageProcess.run(cli: "/usr/bin/printf", args: ["queued"], timeout: 3) }
        try await Task.sleep(for: .milliseconds(30))
        let start = Date()
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Queued helper must be cancelled before launching") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        first.cancel()
        second.cancel()
        _ = try? await first.value
        _ = try? await second.value
    }
    func testInheritedPipeDoesNotDelayParentCompletion() async throws {
        let start = Date()
        let result = try await UsageProcess.run(cli: "/bin/sh", args: ["-c", "sleep 1 & printf ready"], timeout: 3)
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "ready")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }
    func testProcessCancellationStopsOwnedProcess() async throws {
        let task = Task { try await UsageProcess.run(cli: "/bin/sleep", args: ["5"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testHelperConcurrencyIsLimitedAndFreshProvidersAreNotFetchedAgain() async throws {
        let counter = FetchCounter()
        let provider = UsageProvider(cacheURL: nil, cliPath: "fixture") { name, _ in
            await counter.enter()
            try? await Task.sleep(for: .milliseconds(40))
            await counter.leave()
            return UsageFetchResult(provider: name, usage: ProviderUsage(provider: name, fetchedAt: Date(), windows: [
                .init(id: name, label: "한도", group: nil, usedPercent: 12, resetsAt: nil, resetDescription: nil)
            ]))
        }
        defer { provider.stop() }
        provider.refresh()
        let deadline = Date().addingTimeInterval(3)
        while provider.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(provider.isRefreshing)
        let values = await counter.values()
        XCTAssertEqual(values.total, 5)
        XCTAssertEqual(values.maximum, 2)
        provider.refreshIfStale(maxAge: 300)
        XCTAssertFalse(provider.isRefreshing)
        let after = await counter.values()
        XCTAssertEqual(after.total, 5)
    }

    func testPerProviderQueueAndProgressDoNotMakeOtherCardsAppearStuck() async throws {
        let provider = UsageProvider(cacheURL: nil, cliPath: "fixture") { name, _ in
            try? await Task.sleep(for: .milliseconds(name == "claude" ? 180 : 45))
            return UsageFetchResult(provider: name, usage: ProviderUsage(provider: name, fetchedAt: Date()))
        }
        defer { provider.stop() }
        provider.refresh(providers: ["codex", "claude", "antigravity"])
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(provider.progress?.total, 3)
        XCTAssertTrue(provider.usages.first { $0.provider == "codex" }?.refreshState.isPending == true)
        XCTAssertEqual(provider.usages.first { $0.provider == "antigravity" }?.refreshState, .queued)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThanOrEqual(provider.progress?.completed ?? 0, 1)
        XCTAssertEqual(provider.usages.first { $0.provider == "codex" }?.refreshState, .idle)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(provider.isRefreshing)
        XCTAssertNil(provider.progress)
    }

    func testWholeRoundDeadlineRestoresControlsEvenIfSourceIgnoresCancellation() async throws {
        let gate = UsageResultGate()
        let provider = UsageProvider(cacheURL: nil, cliPath: "fixture", roundTimeout: 0.06) { name, _ in
            await gate.wait()
            return UsageFetchResult(provider: name, usage: ProviderUsage(provider: name, fetchedAt: Date()))
        }
        provider.refresh(providers: ["antigravity"])
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(provider.isRefreshing)
        XCTAssertNil(provider.progress)
        XCTAssertEqual(provider.usages.first { $0.provider == "antigravity" }?.refreshState, .idle)
        XCTAssertTrue(provider.usages.first { $0.provider == "antigravity" }?.issue?.contains("중단") == true)
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(provider.usages.first { $0.provider == "antigravity" }?.fetchedAt)
        provider.stop()
    }

    func testCancelledLateResultCannotOverwriteNewRound() async throws {
        let gate = UsageResultGate()
        let provider = UsageProvider(cacheURL: nil, cliPath: "fixture") { name, _ in
            await gate.wait()
            return UsageFetchResult(provider: name, usage: ProviderUsage(provider: name, plan: "late", fetchedAt: Date()))
        }
        provider.refresh(providers: ["claude"])
        try await Task.sleep(for: .milliseconds(25))
        provider.cancelRefresh()
        XCTAssertFalse(provider.isRefreshing)
        XCTAssertNil(provider.progress)
        XCTAssertTrue(provider.statusText.contains("조회 취소됨"))
        XCTAssertFalse(provider.statusText.contains("실패"))
        provider.apply(UsageFetchResult(provider: "claude", usage: ProviderUsage(provider: "claude", plan: "current", fetchedAt: Date())))
        provider.publish()
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.usages.first { $0.provider == "claude" }?.plan, "current")
        provider.stop()
    }

    func testNextDayValuesStayHistoricalAndLoadingStateIsNotCached() throws {
        var usage = try XCTUnwrap(UsageProvider.decode(fixture(), provider: "antigravity", now: now).usage)
        usage.refreshState = .loading(now.addingTimeInterval(10))
        XCTAssertFalse(usage.hasCurrentValues(at: now.addingTimeInterval(86400)))
        XCTAssertEqual(usage.refreshState.text(at: now.addingTimeInterval(25)), "조회 중 · 15초")
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(ProviderUsage.self, from: data)
        XCTAssertEqual(decoded.refreshState, .idle)
        XCTAssertEqual(decoded.fetchedAt, now)
        XCTAssertEqual(decoded.lastObservationText(at: now.addingTimeInterval(86400)), "마지막 확인 10/30 10:07")
    }
}

private actor UsageResultGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor FetchCounter {
    var active = 0
    var total = 0
    var maximum = 0
    func enter() { active += 1; total += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
    func values() -> (total: Int, maximum: Int) { (total, maximum) }
}
