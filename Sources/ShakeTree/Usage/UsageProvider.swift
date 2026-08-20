import Foundation

// MARK: - codexbar CLI JSON 모델 (필요한 필드만)

struct CodexBarEntry: Decodable, Sendable {
    let provider: String
    let usage: Usage

    struct Usage: Decodable, Sendable {
        let loginMethod: String?
        let primary: Window?
        let secondary: Window?
        let extraRateWindows: [ExtraWindow]?
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let resetsAt: String?
        let resetDescription: String?
        let windowMinutes: Int?
    }

    struct ExtraWindow: Decodable, Sendable {
        let title: String
        let window: Window
    }
}

/// 표시용으로 정리한 사용량
struct ProviderUsage: Sendable, Identifiable {
    var id: String { provider }
    let provider: String  // "codex" / "claude"
    let plan: String?
    let windows: [WindowDisplay]

    struct WindowDisplay: Sendable, Identifiable {
        var id: String { label }
        let label: String
        let usedPercent: Double
        let resetText: String?
    }
}

// MARK: - 조회

@MainActor
final class UsageProvider: ObservableObject {
    @Published var usages: [ProviderUsage] = []
    @Published var statusText: String = "사용량 불러오는 중…"

    private var timer: Timer?
    var onUpdate: (() -> Void)?

    static var cliPath: String? {
        var candidates: [String] = []
        // 1순위: 앱 번들에 함께 넣은 codexbar CLI (CodexBar 앱 없이도 동작)
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/codexbar-cli").path)
        // 2순위: CodexBar 앱이 아직 설치돼 있으면 그 심볼릭 링크
        candidates += ["/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(interval: TimeInterval = 300) {
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard let cli = Self.cliPath else {
            statusText = "사용량 CLI 없음 (앱 재설치 필요)"
            onUpdate?()
            return
        }
        Task {
            // 프로바이더별로 따로 조회하므로 일부만 실패할 수 있다. 성공한 것만이라도
            // 보여주고, 전부 실패했을 때만 이전 값을 남긴 채 상태 줄로 알린다.
            let entries = await Self.fetch(cli: cli)
            if entries.isEmpty {
                self.statusText = "사용량 조회 실패 (로그인 상태 확인)"
            } else {
                self.usages = entries.map(Self.display(from:))
                let time = Date().formatted(date: .omitted, time: .shortened)
                self.statusText = "업데이트: \(time)"
            }
            self.onUpdate?()
        }
    }

    /// 한 번의 호출로 다 가져올 수 없어서 프로바이더별로 나눠 부른다.
    /// `--source`는 호출 전체에 걸리는 옵션인데 프로바이더마다 읽어야 할 곳이 다르기 때문이다:
    /// Codex/Claude는 CLI에 로그인된 계정(cli), Grok은 브라우저 쿠키, Antigravity는 설치된
    /// 앱 상태에서 읽는다. `--provider all`은 60개가 넘는 프로바이더를 전부 훑느라 느리고
    /// 대부분 "로그인 안 됨" 오류만 돌려주므로 쓰지 않는다.
    ///
    /// Codex/Claude에 `--source cli`를 주는 이유: 기본값(web)은 Chrome 기본 프로필의
    /// claude.ai 쿠키를 읽어서, 브라우저에 다른 계정이 로그인돼 있으면 정작 내가 한도를
    /// 쓰고 있는 계정이 아닌 쪽의 사용량(대개 0%)이 표시된다.
    private nonisolated static let queries: [[String]] = [
        ["usage", "--provider", "both", "--source", "cli", "--json"],
        ["usage", "--provider", "grok", "--json"],
        ["usage", "--provider", "antigravity", "--json"],
    ]

    /// 메뉴에 세로로 쌓이는 순서. 조회는 병렬이라 끝나는 순서가 매번 달라서,
    /// 그대로 두면 메뉴 항목이 갱신될 때마다 위아래로 뒤바뀐다.
    private nonisolated static let providerOrder = ["codex", "claude", "grok", "antigravity"]

    private nonisolated static func fetch(cli: String) async -> [CodexBarEntry] {
        let entries = await withTaskGroup(of: [CodexBarEntry].self) { group in
            for args in queries {
                group.addTask {
                    guard let data = try? await run(cli: cli, args: args) else { return [] }
                    return decode(data)
                }
            }
            var all: [CodexBarEntry] = []
            for await part in group { all += part }
            return all
        }
        return entries.sorted {
            (providerOrder.firstIndex(of: $0.provider) ?? .max)
                < (providerOrder.firstIndex(of: $1.provider) ?? .max)
        }
    }

    private nonisolated static func run(cli: String, args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: cli)
                task.arguments = args
                let out = Pipe()
                task.standardOutput = out
                task.standardError = Pipe()
                do {
                    try task.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 프로바이더 하나(예: 쿠키 만료로 Claude 조회 실패)가 usage 대신 error 필드를 내보내면
    /// 배열 전체를 [CodexBarEntry]로 한 번에 디코드할 때 전체가 실패해버린다.
    /// 항목별로 개별 디코드해서 실패한 프로바이더만 건너뛰고 나머지는 살린다.
    private nonisolated static func decode(_ data: Data) -> [CodexBarEntry] {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return (try? JSONDecoder().decode([CodexBarEntry].self, from: data)) ?? []
        }
        let decoder = JSONDecoder()
        return rawArray.compactMap { dict in
            guard let entryData = try? JSONSerialization.data(withJSONObject: dict) else {
                return nil
            }
            return try? decoder.decode(CodexBarEntry.self, from: entryData)
        }
    }

    private static func display(from entry: CodexBarEntry) -> ProviderUsage {
        let extras = entry.usage.extraRateWindows ?? []
        var windows: [ProviderUsage.WindowDisplay] = []
        var titledAlreadyShown = Set<String>()

        func date(_ window: CodexBarEntry.Window) -> Date? {
            window.resetsAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        }

        /// 2열 배치라 한 칸이 좁다. 오늘 리셋되는 창은 시각만, 그 이후는 날짜만 —
        /// 오늘 것은 몇 시에 풀리는지가, 며칠 뒤 것은 며칠인지가 궁금한 정보다.
        func resetText(_ window: CodexBarEntry.Window) -> String? {
            guard let date = date(window) else { return window.resetDescription }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d"
            return formatter.string(from: date) + " 리셋"
        }

        /// 창 길이로 이름을 붙인다. 예전엔 10080분(7일)만 "주간"으로 알아보고 나머지는
        /// fallback으로 흘려서, Codex의 43200분(30일) 한도가 "세션"으로 표시됐다.
        /// 창 길이를 아예 안 알려주는 프로바이더(Grok)는 기간을 단정하지 않고 "한도"로 둔다.
        func label(for window: CodexBarEntry.Window) -> String {
            guard let minutes = window.windowMinutes else { return "한도" }
            switch minutes {
            case ..<600: return "세션"  // 5~10시간짜리 롤링 윈도우
            case ..<20160: return "주간"  // 7일
            default: return "월간"  // 30일 이상
            }
        }

        /// primary/secondary가 제목 붙은 extraRateWindows와 같은 창을 가리키는 경우가 있다
        /// (Antigravity는 primary=Gemini 5-hour, secondary=Claude/GPT 5-hour로 겹친다).
        /// 리셋 시각이 사실상 같으면 같은 창으로 보고, 정보가 많은 제목 쪽을 쓴다.
        /// 창마다 조회 시각이 조금씩 달라 몇 분씩 어긋나므로 여유를 둔다.
        func title(matching window: CodexBarEntry.Window) -> String? {
            guard let target = date(window) else { return nil }
            return extras.first { extra in
                extra.window.windowMinutes == window.windowMinutes
                    && date(extra.window).map { abs($0.timeIntervalSince(target)) < 600 } == true
            }?.title
        }

        func append(_ window: CodexBarEntry.Window?) {
            guard let window else { return }
            let matched = title(matching: window)
            if let matched { titledAlreadyShown.insert(matched) }
            windows.append(
                .init(
                    label: matched ?? label(for: window), usedPercent: window.usedPercent,
                    resetText: resetText(window)))
        }

        append(entry.usage.primary)
        append(entry.usage.secondary)
        // 남은 제목 창들. 예전엔 usedPercent > 0인 것만 보여줬는데, 그러면 아직 안 쓴 한도가
        // 통째로 사라진다 (Antigravity의 Claude/GPT 창이 0%라 안 보이던 문제).
        for extra in extras where !titledAlreadyShown.contains(extra.title) {
            windows.append(
                .init(
                    label: extra.title, usedPercent: extra.window.usedPercent,
                    resetText: resetText(extra.window)))
        }

        return ProviderUsage(
            provider: entry.provider, plan: entry.usage.loginMethod, windows: windows)
    }
}
