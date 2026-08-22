import Foundation

// MARK: - codexbar CLI JSON 모델 (필요한 필드만)

struct CodexBarEntry: Decodable, Sendable {
    var provider: String
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
        let id: String
        let title: String
        let window: Window
    }
}

/// 표시용으로 정리한 사용량
struct ProviderUsage: Sendable, Identifiable {
    var id: String { provider }
    let provider: String  // "codex" / "claude" / "gemini" / "grok"
    let plan: String?
    let windows: [WindowDisplay]
    /// 접힌 부가 한도(Spark 등) — 평소엔 숨기고 카드에서 토글로 펼쳐 본다.
    let sparkWindows: [WindowDisplay]

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

    /// 프로바이더별 마지막 성공값. 조회 출처 중 웹 쿠키 기반(Codex oauth, Grok)은
    /// 브라우저 상태에 따라 한 번씩 실패할 때가 있다 — 그때마다 카드가 깜빡 사라지면
    /// 산만하므로, 한 번 성공한 값은 다음 성공까지 붙잡아 둔다.
    private var lastGood: [String: ProviderUsage] = [:]

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
            let fresh = entries.map(Self.display(from:))
            for usage in fresh { lastGood[usage.provider] = usage }

            // 이번 라운드에서 못 받아온 프로바이더는 마지막 성공값으로 메운다 —
            // 일시적 실패(쿠키 읽기 경쟁, 네트워크)로 카드가 깜빡 사라지지 않게.
            var merged = fresh
            for (provider, usage) in lastGood
            where !fresh.contains(where: { $0.provider == provider }) {
                merged.append(usage)
            }
            merged.sort {
                Self.providerOrder.firstIndex(of: $0.provider) ?? .max
                    < Self.providerOrder.firstIndex(of: $1.provider) ?? .max
            }

            if merged.isEmpty {
                self.statusText = "사용량 조회 실패 (로그인 상태 확인)"
            } else {
                self.usages = merged
                let time = Date().formatted(date: .omitted, time: .shortened)
                self.statusText = "업데이트: \(time)"
            }
            self.onUpdate?()
        }
    }

    /// 한 번의 호출로 다 가져올 수 없어서 나눠 부른다. 배열 순서 = 우선순위.
    /// 같은 프로바이더가 여러 쿼리에서 돌아오면 앞쪽(정확한) 결과를 쓴다.
    ///
    /// 첫 줄에 `--source cli`를 두는 이유: 기본값(web)은 Chrome 기본 프로필의
    /// claude.ai/chatgpt.com 쿠키를 읽어서, 브라우저에 다른 계정이 로그인돼 있으면
    /// 정작 내가 한도를 쓰고 있는 계정이 아닌 쪽의 사용량(대개 0%)이 표시된다.
    /// 그렇다고 cli만 쓰면 안 된다 — 설치된 Codex CLI 버전에 따라 codexbar가 넘기는
    /// `--ask-for-approval untrusted` 값이 거부되어 Codex 조회가 통째로 실패하는데
    //(실제 0.149.0에서 재현), oauth(웹 로그인) 경로는 멀쩡히 돌아온다.
    /// 그래서 cli 성공분을 우선하고, 비어 있으면 web 결과로 채운다.
    ///
    /// Grok은 브라우저 쿠키, Antigravity는 설치된 앱 상태에서 읽는다.
    /// `--provider all`은 60개가 넘는 프로바이더를 전부 훑느라 느리고 대부분
    /// "로그인 안 됨" 오류만 돌려주므로 쓰지 않는다.
    private nonisolated static let queries: [[String]] = [
        // `--json`은 상태 메시지가 JSON 앞에 섞일 수 있다. 그러면 배열 전체가
        // 디코드되지 않아 카드가 통째로 사라진다. 내장 CLI의 `--json-only`는
        // stdout을 JSON으로만 제한한다.
        ["usage", "--provider", "both", "--source", "cli", "--json-only"],
        ["usage", "--provider", "both", "--json-only"],  // 폴백: oauth/웹 소스
        ["usage", "--provider", "grok", "--json-only"],
        ["usage", "--provider", "gemini", "--json-only"],
        // Gemini CLI에 로그인돼 있지 않을 때의 대체 공급원. Antigravity가 자기 안에서
        // 쓰는 Gemini 한도를 보고하는데, 그것도 결국 같은 Gemini 사용량이다.
        ["usage", "--provider", "antigravity", "--json-only"],
    ]

    /// 메뉴에 세로로 쌓이는 순서. 조회는 병렬이라 끝나는 순서가 매번 달라서,
    /// 그대로 두면 메뉴 항목이 갱신될 때마다 위아래로 뒤바뀐다.
    private nonisolated static let providerOrder = ["codex", "claude", "gemini", "grok"]

    private nonisolated static func fetch(cli: String) async -> [CodexBarEntry] {
        // 쿼리별로 결과를 나눠 받는다 — 같은 프로바이더가 여러 쿼리에서 돌아오면
        // 우선순위가 높은(배열 앞쪽) 쪽을 남기기 위해서다.
        let byQuery = await withTaskGroup(
            of: (index: Int, entries: [CodexBarEntry]).self
        ) { group in
            for (index, args) in queries.enumerated() {
                group.addTask {
                    guard let data = try? await run(cli: cli, args: args) else {
                        return (index, [])
                    }
                    return (index, decode(data))
                }
            }
            var result = [[CodexBarEntry]](repeating: [], count: queries.count)
            for await (index, entries) in group { result[index] = entries }
            return result
        }

        var ranked: [(entry: CodexBarEntry, rank: Int)] = []
        for (rank, entries) in byQuery.enumerated() {
            for entry in entries { ranked.append((entry, rank)) }
        }

        // Gemini 사용량은 두 곳에서 올 수 있다. 전용 CLI가 로그인돼 있으면 그쪽이
        // 정확하고, 없으면 Antigravity가 보고하는 Gemini 한도로 대신한다 — 표시할 땐
        // 둘 다 그냥 "Gemini"다. 어느 쪽에서 왔는지는 쓰는 사람에게 중요하지 않다.
        let hasNativeGemini = ranked.contains { $0.entry.provider == "gemini" }
        let normalized = ranked.map { item -> (entry: CodexBarEntry, rank: Int) in
            guard item.entry.provider == "antigravity", !hasNativeGemini else { return item }
            var remapped = item.entry
            remapped.provider = "gemini"
            return (remapped, item.rank)
        }

        // 같은 프로바이더가 여러 출처에서 오면(cl성공 + web 폴백 등) 순위 하나만
        // 남긴다. 같은 ID가 SwiftUI ForEach에 두 번 들어가면 카드가 누락될 수 있다.
        var best: [String: (entry: CodexBarEntry, rank: Int)] = [:]
        for item in normalized where providerOrder.contains(item.entry.provider) {
            if let current = best[item.entry.provider] {
                if item.rank < current.rank { best[item.entry.provider] = item }
            } else {
                best[item.entry.provider] = item
            }
        }
        return providerOrder.compactMap { best[$0]?.entry }
    }

    private nonisolated static let processTimeout: TimeInterval = 15

    private nonisolated static func run(cli: String, args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: cli)
                task.arguments = args
                let out = Pipe()
                task.standardOutput = out
                // stderr는 화면에 쓰지 않으면서도, 읽지 않는 Pipe가 가득 차 하위
                // 프로세스가 멈추는 문제를 피한다.
                task.standardError = FileHandle.nullDevice
                do {
                    try task.run()
                    // 감시자 — CLI가 어쩌다 멈추면 종료시켜 파이프 EOF로 만든다.
                    // 안 그러면 readDataToEndOfFile이 영원히 돌아오지 않는다.
                    let watchdog = DispatchWorkItem {
                        if task.isRunning { task.terminate() }
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + processTimeout, execute: watchdog)
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    watchdog.cancel()
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
        if let entries = decodeJSONArray(data) { return entries }

        // 이전 버전의 CLI나 하위 CLI가 상태 메시지를 stdout에 쓰더라도 실제 JSON
        // 배열은 살린다. `--json-only`가 기본 방어선이고, 이 코드는 호환성 안전망이다.
        for payload in jsonArrayPayloads(in: data) {
            if let entries = decodeJSONArray(payload) { return entries }
        }
        return []
    }

    /// JSON 배열을 항목별로 디코드한다. 한 프로바이더의 오류가 나머지까지 숨기지 않게 한다.
    private nonisolated static func decodeJSONArray(_ data: Data) -> [CodexBarEntry]? {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return try? JSONDecoder().decode([CodexBarEntry].self, from: data)
        }
        let decoder = JSONDecoder()
        return rawArray.compactMap { dict in
            guard let entryData = try? JSONSerialization.data(withJSONObject: dict) else {
                return nil
            }
            return try? decoder.decode(CodexBarEntry.self, from: entryData)
        }
    }

    /// stdout 앞뒤에 로그가 붙은 경우, 문자열/이스케이프를 고려해 온전한 JSON 배열만 찾는다.
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
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    insideString = false
                }
                continue
            }

            switch character {
            case "\"":
                insideString = true
            case "[":
                if depth == 0 { start = index }
                depth += 1
            case "]":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start {
                    payloads.append(Data(text[start...index].utf8))
                }
            default:
                break
            }
        }
        return payloads
    }

    private static func display(from entry: CodexBarEntry) -> ProviderUsage {
        // Antigravity는 Gemini 한도와, 그 안에서 쓰는 서드파티 모델(Claude/GPT) 한도를
        // 같이 준다 — id의 "3p"가 third-party다. 이 카드는 Gemini 사용량이므로 뺀다.
        let allExtras = entry.usage.extraRateWindows ?? []
        let nonThirdParty = allExtras.filter { !$0.id.contains("-3p-") }
        // Spark 한도는 잘 안 쓰는 부가 창이라 접어서 따로 모은다 —
        // 카드의 "Spark" 토글을 눌러야 펼쳐진다.
        let sparkExtras = nonThirdParty.filter { $0.id.lowercased().contains("spark") }
        let extras = nonThirdParty.filter { !$0.id.lowercased().contains("spark") }
        var windows: [ProviderUsage.WindowDisplay] = []
        var sparkWindows: [ProviderUsage.WindowDisplay] = []

        func date(_ window: CodexBarEntry.Window) -> Date? {
            window.resetsAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        }

        /// 2열 배치라 한 칸이 좁다. 오늘 리셋되는 창은 시각만, 그 이후는 날짜만 —
        /// 오늘 것은 몇 시에 풀리는지가, 며칠 뒤 것은 며칠인지가 궁금한 정보다.
        /// "리셋"이라는 말은 붙이지 않는다. 게이지 바로 옆에 놓이는 시각이라 문맥으로
        /// 읽히고, 그 두 글자가 한 칸의 폭을 잡아먹는다.
        func resetText(_ window: CodexBarEntry.Window) -> String? {
            guard let date = date(window) else { return window.resetDescription }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d"
            return formatter.string(from: date)
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
        func sameWindow(_ a: CodexBarEntry.Window, _ b: CodexBarEntry.Window) -> Bool {
            guard a.windowMinutes == b.windowMinutes, let x = date(a), let y = date(b) else {
                return false
            }
            return abs(x.timeIntervalSince(y)) < 600
        }

        /// 영어로 된 창 제목("Gemini 5-hour")을 다른 카드와 같은 세션/주간 표기로 바꾼다.
        /// 카드 제목이 이미 "Gemini"라 창 이름에 모델명을 또 붙일 필요가 없다.
        func shorten(_ title: String) -> String {
            title
                .replacingOccurrences(of: "Codex ", with: "")
                .replacingOccurrences(of: "Gemini ", with: "")
                .replacingOccurrences(of: "5-hour", with: "세션")
                .replacingOccurrences(of: "weekly", with: "주간")
                .replacingOccurrences(of: "Weekly", with: "주간")
        }

        // 제목(id)이 붙은 창을 먼저 쓴다. 어떤 한도인지 분명하고 순서도 일정하기 때문이다.
        // primary/secondary는 그중 일부를 가리키기만 하는데 무엇을 가리킬지가 일정하지
        // 않다 — Antigravity는 primary가 5시간 창일 때도, 주간 창일 때도 있다.
        for extra in extras {
            windows.append(
                .init(
                    label: shorten(extra.title), usedPercent: extra.window.usedPercent,
                    resetText: resetText(extra.window)))
        }
        for extra in sparkExtras {
            sparkWindows.append(
                .init(
                    label: shorten(extra.title), usedPercent: extra.window.usedPercent,
                    resetText: resetText(extra.window)))
        }

        /// 제목 있는 창이 이미 다룬 한도인지. 감출 서드파티 창까지 함께 대조한다 —
        /// Antigravity의 Gemini 5시간 창과 Claude/GPT 5시간 창은 리셋 시각이 완전히
        /// 같아서, 시각만으로는 primary/secondary가 둘 중 어느 쪽인지 가릴 수 없다.
        /// 어느 쪽이든 제목 있는 창이 그 자리를 채우므로 그냥 건너뛰면 된다.
        func covered(_ window: CodexBarEntry.Window) -> Bool {
            allExtras.contains { sameWindow(window, $0.window) }
        }

        // 제목 있는 창이 아예 없는 프로바이더(Codex/Claude/Grok)는 여기서만 채워진다.
        func append(_ window: CodexBarEntry.Window?) {
            guard let window, !covered(window) else { return }
            windows.append(
                .init(
                    label: label(for: window), usedPercent: window.usedPercent,
                    resetText: resetText(window)))
        }

        append(entry.usage.primary)
        append(entry.usage.secondary)

        return ProviderUsage(
            provider: entry.provider, plan: entry.usage.loginMethod, windows: windows,
            sparkWindows: sparkWindows)
    }
}
