import Foundation

struct UsageFetchResult: Sendable {
    let provider: String
    var usage: ProviderUsage? = nil
    var issue: String? = nil
}

enum UsageRefreshState: Equatable, Sendable {
    case idle
    case queued
    case loading(Date)
    var isPending: Bool { self != .idle }
    func text(at _: Date) -> String? {
        switch self {
        case .idle: nil
        case .queued: "갱신 대기"
        case .loading(_): "갱신 중"
        }
    }
}

struct UsageRefreshProgress: Equatable, Sendable {
    let startedAt: Date
    let total: Int
    let completed: Int
    func text(at _: Date) -> String {
        "백그라운드 갱신 · \(completed)/\(total)"
    }
}

struct ProviderUsage: Sendable, Identifiable, Codable, Equatable {
    var displayName: String {
        switch provider {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "antigravity": "Antigravity"
        case "gemini": "Gemini CLI"
        case "grok": "Grok"
        default: provider
        }
    }
    static let geminiMigrationNotice = "개인 계정 한도는 Antigravity에서 확인"
    static let externalSharedGroupTitle = "외부 모델 공유 한도"
    static let externalSharedGroupExplanation = "안티그래비티 안에서 Claude·GPT-OSS 등이 함께 쓰는 한도입니다. 사용한 모델 목록을 뜻하지 않으며, Claude Code·ChatGPT의 별도 구독 한도와는 관계없습니다."
    var id: String { provider }
    let provider: String
    var plan: String? = nil
    var account: String? = nil
    var source: String? = nil
    var fetchedAt: Date? = nil
    var windows: [WindowDisplay] = []
    var sparkWindows: [WindowDisplay] = []
    var issue: String? = nil
    // Transient scheduling state is never written into the quota cache.
    var refreshState: UsageRefreshState = .idle
    private enum CodingKeys: String, CodingKey {
        case provider, plan, account, source, fetchedAt, windows, sparkWindows, issue
    }
    var isNotice: Bool { issue == Self.geminiMigrationNotice }

    /// Keep the provider's raw quota identity intact, including older cached values.
    /// Only the user-facing name changes; no model-specific usage is inferred.
    func displayGroup(_ raw: String?) -> String? {
        guard provider == "antigravity", let raw,
              ["Claude / GPT", "Claude/GPT", "Claude and GPT", "Claude and GPT models"].contains(raw)
        else { return raw }
        return Self.externalSharedGroupTitle
    }

    struct WindowDisplay: Sendable, Identifiable, Codable, Equatable {
        let id: String
        let label: String
        let group: String?
        let usedPercent: Double
        let resetsAt: Date?
        let resetDescription: String?
        func resetText(at now: Date = Date()) -> String? {
            guard let resetsAt else { return resetDescription }
            if resetsAt <= now { return "리셋 후 재조회 필요" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = Calendar.current.isDate(resetsAt, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
            return formatter.string(from: resetsAt)
        }
    }
    func isStale(at now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > 3600
    }
    func canShow(_ window: WindowDisplay, at now: Date = Date()) -> Bool {
        guard !isStale(at: now) else { return false }
        if let resetsAt = window.resetsAt, resetsAt <= now { return false }
        return true
    }
    func hasCurrentValues(at now: Date) -> Bool {
        (windows + sparkWindows).contains { canShow($0, at: now) }
    }
    func lastObservationText(at now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = Calendar.current.isDate(fetchedAt, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return "마지막 확인 \(formatter.string(from: fetchedAt))"
    }
    func freshnessText(at now: Date = Date()) -> String {
        guard let fetchedAt else { return issue ?? "아직 조회 전" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = Calendar.current.isDate(fetchedAt, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        let prefix = issue != nil || isStale(at: now) ? "이전 값" : "조회"
        return "\(prefix) \(formatter.string(from: fetchedAt))"
    }
}

struct CodexBarEntry: Decodable, Sendable {
    let provider: String
    let source: String?
    let usage: Usage?
    let error: CLIError?
    let rateWindowLabels: Labels?
    struct CLIError: Decodable, Sendable { let message: String }
    struct Labels: Decodable, Sendable {
        let primary: String?
        let secondary: String?
        let tertiary: String?
    }
    struct Identity: Decodable, Sendable {
        let accountEmail: String?
        let loginMethod: String?
    }
    struct Usage: Decodable, Sendable {
        let loginMethod: String?
        let identity: Identity?
        let updatedAt: String?
        let primary: Window?
        let secondary: Window?
        let tertiary: Window?
        let extraRateWindows: [ExtraWindow]?
    }
    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let resetsAt: String?
        let resetDescription: String?
        let windowMinutes: Int?
        let isSyntheticPlaceholder: Bool?
        var isMeasured: Bool {
            isSyntheticPlaceholder != true && usedPercent.isFinite && (0...100).contains(usedPercent)
        }
    }
    struct ExtraWindow: Decodable, Sendable {
        let id: String
        let title: String
        let window: Window
    }
    nonisolated static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }
    nonisolated func display(now: Date) -> ProviderUsage? {
        guard let usage else { return nil }
        var result = ProviderUsage(provider: provider,
            plan: usage.identity?.loginMethod ?? usage.loginMethod,
            account: usage.identity?.accountEmail, source: source,
            fetchedAt: Self.date(usage.updatedAt).map { min($0, now) } ?? now)
        var added: [(group: String?, window: Window)] = []
        func period(_ window: Window) -> String {
            guard let minutes = window.windowMinutes, minutes > 0 else { return "한도" }
            if minutes < 60 { return "\(minutes)분" }
            if minutes < 1440 { return "\(minutes / 60)시간" }
            if minutes % 10080 == 0 { return "\(minutes / 10080)주일" }
            return "\(minutes / 1440)일"
        }
        func groupName(_ title: String?, id: String = "") -> String? {
            guard provider == "antigravity" else {
                if ["Session", "Weekly", "Monthly", "Primary", "Secondary"].contains(title ?? "") { return nil }
                return title
            }
            let name = title?.replacingOccurrences(
                of: #"\s+(5[- ]hour|weekly|monthly|session|daily)$"#,
                with: "", options: .regularExpression)
            if ["Claude/GPT", "Claude and GPT", "Claude and GPT models"].contains(name ?? "") { return "Claude / GPT" }
            if ["Gemini", "Gemini Models"].contains(name ?? "") { return "Gemini" }
            if let name, !name.isEmpty { return name }
            if id.contains("-3p-") { return "Claude / GPT" }
            if id.contains("gemini") { return "Gemini" }
            return nil
        }
        func append(_ window: Window?, id: String, group: String?, spark: Bool = false) {
            guard let window, window.isMeasured else { return }
            // Same reset time alone does not establish the same model/quota.
            if added.contains(where: { existing in
                existing.group == group && existing.window.windowMinutes == window.windowMinutes
                    && existing.window.usedPercent == window.usedPercent
                    && existing.window.resetsAt == window.resetsAt
            }) { return }
            let display = ProviderUsage.WindowDisplay(id: "\(provider)-\(id)", label: period(window),
                group: group, usedPercent: window.usedPercent, resetsAt: Self.date(window.resetsAt),
                resetDescription: window.resetDescription)
            if spark { result.sparkWindows.append(display) } else { result.windows.append(display) }
            added.append((group, window))
        }
        for extra in usage.extraRateWindows ?? [] {
            append(extra.window, id: extra.id, group: groupName(extra.title, id: extra.id),
                   spark: extra.id.lowercased().contains("spark"))
        }
        append(usage.primary, id: "primary",
               group: groupName(rateWindowLabels?.primary ?? (provider == "antigravity" ? "Gemini" : nil)))
        append(usage.secondary, id: "secondary",
               group: groupName(rateWindowLabels?.secondary ?? (provider == "antigravity" ? "Claude / GPT" : nil)))
        append(usage.tertiary, id: "tertiary", group: groupName(rateWindowLabels?.tertiary))
        return result
    }
}
