import Foundation

@MainActor
final class UsageProvider: ObservableObject {
    @Published private(set) var usages: [ProviderUsage] = []
    @Published private(set) var statusText = "사용량 조회 전"
    private(set) var isRefreshing = false
    private(set) var progress: UsageRefreshProgress?
    var onUpdate: (() -> Void)?
    nonisolated static let providerOrder = ["codex", "claude", "antigravity", "gemini", "grok"]
    private var lastGood: [String: ProviderUsage] = [:]
    private var issues: [String: String] = [:]
    private var lastAttempt: Date?
    private var providerAttempts: [String: Date] = [:]
    private var isPanelVisible = false
    private let fetcher: @Sendable (String, String) async -> UsageFetchResult
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var pending: [String: UsageRefreshState] = [:]
    private var completedCount = 0
    private var targetCount = 0
    private var roundStartedAt: Date?
    private var roundNotice: String?
    private let roundTimeout: TimeInterval
    private var hasBeenRequested = false
    private var generation = 0
    private let cacheURL: URL?
    private let cliOverride: String?

    init(cacheURL: URL? = UsageProvider.defaultCacheURL, cliPath: String? = nil,
         roundTimeout: TimeInterval = 45,
         fetcher: @escaping @Sendable (String, String) async -> UsageFetchResult = UsageProvider.fetch) {
        self.cacheURL = cacheURL
        self.cliOverride = cliPath
        self.fetcher = fetcher
        self.roundTimeout = roundTimeout
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(UsageCache.self, from: data), cache.version == 2 {
            for usage in cache.usages where Self.providerOrder.contains(usage.provider)
                && usage.fetchedAt != nil && (!usage.windows.isEmpty || !usage.sparkWindows.isEmpty) {
                lastGood[usage.provider] = usage
            }
            if cache.notices?["gemini"] == ProviderUsage.geminiMigrationNotice {
                issues["gemini"] = ProviderUsage.geminiMigrationNotice
            }
        }
        publish()
    }

    // v1 renamed Antigravity as Gemini and discarded observation timestamps.
    // Its identity cannot be recovered safely. Keep it intact; start a v2 cache.
    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ShakeTree/usage-cache-v2.json")
    }
    static var cliPath: String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codexbar-cli").path,
            "/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func start(interval: TimeInterval = 900) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasBeenRequested, self.isPanelVisible else { return }
                self.refreshIfStale(maxAge: 300)
            }
        }
        timer.tolerance = min(60, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() {
        saveCache()
        generation &+= 1
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        pending.removeAll()
        progress = nil
        isRefreshing = false
        publish()
    }

    func cancelRefresh(reason: String = "조회를 취소했습니다") {
        guard isRefreshing else { return }
        generation &+= 1
        if reason == "조회를 취소했습니다" {
            roundNotice = "조회 취소됨 · 마지막 확인 값 표시"
        } else {
            roundNotice = nil
            for provider in pending.keys where issues[provider] != ProviderUsage.geminiMigrationNotice {
                issues[provider] = reason
            }
        }
        pending.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        isRefreshing = false
        progress = nil
        saveCache()
        publish()
    }
    func refreshIfStale(maxAge: TimeInterval, providers: [String]? = nil) {
        hasBeenRequested = true
        let now = Date()
        let due = (providers ?? Self.providerOrder).filter { provider in
            if issues[provider] == nil, let date = lastGood[provider]?.fetchedAt,
               now.timeIntervalSince(date) < maxAge { return false }
            if let attempted = providerAttempts[provider] {
                let retryDelay: TimeInterval = issues[provider]?.contains("개인 계정 한도") == true ? 1800 : 300
                if now.timeIntervalSince(attempted) < retryDelay { return false }
            }
            return true
        }
        guard !due.isEmpty else { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 60 { return }
        refresh(providers: due)
    }
    func setPanelVisible(_ visible: Bool, cancelInFlight: Bool = true) {
        isPanelVisible = visible
        if !visible && cancelInFlight && isRefreshing {
            let unfinished = Array(pending.keys)
            cancelRefresh()
            unfinished.forEach { providerAttempts.removeValue(forKey: $0) }
        }
    }

    /// Manual refresh can always retry every provider; automatic refresh is scoped
    /// to due providers. At most two helper processes run at the same time.
    func refresh(providers: [String]? = nil) {
        guard !isRefreshing else { return }
        let targets = (providers ?? Self.providerOrder).filter(Self.providerOrder.contains)
        guard !targets.isEmpty else { return }
        hasBeenRequested = true
        guard let cli = cliOverride ?? Self.cliPath else {
            for provider in Self.providerOrder { issues[provider] = "사용량 CLI 없음 · 앱 재설치 필요" }
            publish()
            return
        }
        isRefreshing = true
        roundNotice = nil
        lastAttempt = Date()
        for provider in targets { providerAttempts[provider] = lastAttempt }
        roundStartedAt = lastAttempt
        completedCount = 0
        targetCount = targets.count
        pending = Dictionary(uniqueKeysWithValues: targets.map { ($0, .queued) })
        generation &+= 1
        let currentGeneration = generation
        let deadline = roundTimeout
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(deadline)) } catch { return }
            guard let self, self.generation == currentGeneration else { return }
            self.cancelRefresh(reason: "응답 시간이 길어 조회를 중단했습니다")
        }
        publish()
        refreshTask = Task { [weak self] in
            guard let fetcher = self?.fetcher else { return }
            await withTaskGroup(of: UsageFetchResult.self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<min(2, targets.count) {
                    if let provider = iterator.next() {
                        self?.pending[provider] = .loading(Date())
                        group.addTask { await fetcher(provider, cli) }
                    }
                }
                self?.publish()
                // An agy cold start must not hold back other providers or the UI.
                for await result in group {
                    guard let self, !Task.isCancelled, self.generation == currentGeneration else {
                        group.cancelAll()
                        break
                    }
                    self.apply(result)
                    self.saveCache()
                    self.pending.removeValue(forKey: result.provider)
                    self.completedCount += 1
                    self.publish()
                    if let provider = iterator.next() {
                        self.pending[provider] = .loading(Date())
                        self.publish()
                        group.addTask { await fetcher(provider, cli) }
                    }
                }
            }
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            self.deadlineTask?.cancel()
            self.deadlineTask = nil
            self.pending.removeAll()
            self.progress = nil
            self.saveCache()
            self.publish()
        }
    }
    func apply(_ result: UsageFetchResult) {
        if let usage = result.usage {
            lastGood[result.provider] = usage
            issues.removeValue(forKey: result.provider)
        } else {
            issues[result.provider] = result.issue ?? "사용량 조회 실패"
        }
    }
    func publish() {
        usages = Self.providerOrder.map { provider in
            var usage = lastGood[provider] ?? ProviderUsage(provider: provider)
            usage.issue = issues[provider]
            usage.refreshState = pending[provider] ?? .idle
            return usage
        }
        if isRefreshing, let started = roundStartedAt {
            progress = UsageRefreshProgress(startedAt: started, total: targetCount, completed: completedCount)
            statusText = "사용량 확인 중"
        }
        else if let roundNotice { statusText = roundNotice }
        else if issues.values.contains(where: { $0 != ProviderUsage.geminiMigrationNotice }) {
            let failures = issues.values.filter { $0 != ProviderUsage.geminiMigrationNotice }.count
            statusText = "\(failures)개 서비스 조회 실패 · 카드별 상태 확인"
        }
        else if !issues.isEmpty { statusText = "조회 완료 · 서비스별 확인 시각 표시" }
        else if lastGood.isEmpty { statusText = "사용량 조회 전" }
        else { statusText = "갱신 시각은 각 카드에 표시됩니다" }
        onUpdate?()
    }
    private struct UsageCache: Codable {
        var version = 2
        var usages: [ProviderUsage]
        var notices: [String: String]? = nil
    }
    private func saveCache() {
        guard let cacheURL else { return }
        var values = Self.providerOrder.compactMap { lastGood[$0] }
        for index in values.indices { values[index].issue = nil }
        let notices = issues.filter { $0.key == "gemini" && $0.value == ProviderUsage.geminiMigrationNotice }
        guard let data = try? JSONEncoder().encode(UsageCache(usages: values, notices: notices)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
    nonisolated static func fetch(provider: String, cli: String) async -> UsageFetchResult {
        // 0.82 Auto reads native Codex OAuth, not an arbitrary browser account.
        var args = ["usage", "--provider", provider, "--json-only"]
        if provider == "claude" { args += ["--source", "cli"] }
        do {
            let output = try await UsageProcess.run(cli: cli, args: args, timeout: provider == "antigravity" ? 35 : 40)
            return decode(output.data, provider: provider, now: Date())
        } catch is CancellationError {
            return UsageFetchResult(provider: provider, issue: "조회 취소됨")
        } catch let error as UsageProcess.Failure {
            return UsageFetchResult(provider: provider, issue: error.safeMessage)
        } catch {
            return UsageFetchResult(provider: provider, issue: "조회기를 실행할 수 없음")
        }
    }
    nonisolated static func decode(_ data: Data, provider: String, now: Date) -> UsageFetchResult {
        var failure: String?
        for payload in [data] + jsonArrayPayloads(in: data) {
            guard let array = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else { continue }
            guard array.contains(where: { $0["provider"] as? String == provider }) else {
                failure = "사용량 응답이 비어 있음"
                continue
            }
            var issue: String?
            for object in array where object["provider"] as? String == provider {
                guard let itemData = try? JSONSerialization.data(withJSONObject: object),
                    let entry = try? JSONDecoder().decode(CodexBarEntry.self, from: itemData) else {
                    issue = "사용량 응답 형식을 읽을 수 없음"
                    continue
                }
                if let usage = entry.display(now: now), !usage.windows.isEmpty || !usage.sparkWindows.isEmpty {
                    return UsageFetchResult(provider: provider, usage: usage)
                }
                issue = entry.error.map { safeIssue($0.message) } ?? "측정 가능한 한도가 없음"
            }
            failure = issue ?? "사용량 응답이 비어 있음"
        }
        return UsageFetchResult(provider: provider, issue: failure ?? "사용량 응답 형식을 읽을 수 없음")
    }
    nonisolated static func safeIssue(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("no longer supports gemini cli oauth") {
            return ProviderUsage.geminiMigrationNotice
        }
        if text.contains("language server not detected") || text.contains("not running") {
            return "Antigravity 앱 또는 agy 로그인 상태 확인"
        }
        if text.contains("403") || text.contains("forbidden") { return "이용 권한 확인 필요 (HTTP 403)" }
        if text.contains("401") || text.contains("sign in") || text.contains("login") || text.contains("credential") {
            return "로그인 상태 확인 필요"
        }
        if text.contains("timeout") || text.contains("timed out") { return "조회 시간 초과 · 다시 시도" }
        if text.contains("network") || text.contains("hostname") || text.contains("connect") { return "네트워크 연결 확인 필요" }
        if text.contains("quota") || text.contains("limit") { return "측정 가능한 한도를 받지 못함" }
        return "사용량 조회 실패 · 로그인·연결 상태 확인"
    }
    private nonisolated static func jsonArrayPayloads(in data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var payloads: [Data] = []
        var start: String.Index?
        var depth = 0
        var insideString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if insideString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { insideString = false }
                continue
            }
            switch character {
            case "\"": insideString = true
            case "[":
                if depth == 0 { start = index }
                depth += 1
            case "]":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start { payloads.append(Data(text[start...index].utf8)) }
            default: break
            }
        }
        return payloads
    }
}
