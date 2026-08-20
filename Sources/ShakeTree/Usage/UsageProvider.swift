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
            do {
                let entries = try await Self.fetch(cli: cli)
                self.usages = entries.map(Self.display(from:))
                let time = Date().formatted(date: .omitted, time: .shortened)
                self.statusText = "업데이트: \(time)"
            } catch {
                self.statusText = "사용량 조회 실패: \(error.localizedDescription)"
            }
            self.onUpdate?()
        }
    }

    private nonisolated static func fetch(cli: String) async throws -> [CodexBarEntry] {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: cli)
                // --source cli: 브라우저 쿠키 대신 각 CLI에 로그인된 계정 기준으로 조회한다.
                // 기본값(web)은 Chrome 기본 프로필의 claude.ai 쿠키를 읽어서, 브라우저에
                // 다른 계정이 로그인돼 있으면 정작 내가 쓰는 계정이 아닌 쪽의 사용량(대개 0%)이
                // 표시된다. 실제로 한도를 쓰는 건 CLI에 로그인된 계정이므로 그쪽을 본다.
                task.arguments = ["usage", "--provider", "both", "--source", "cli", "--json"]
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
        // 프로바이더 하나(예: 쿠키 만료로 Claude 조회 실패)가 null 필드를 내보내면
        // 배열 전체를 [CodexBarEntry]로 한 번에 디코드할 때 전체가 실패해버린다.
        // 항목별로 개별 디코드해서 실패한 프로바이더만 건너뛰고 나머지는 살린다.
        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return try JSONDecoder().decode([CodexBarEntry].self, from: data)
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
        var windows: [ProviderUsage.WindowDisplay] = []

        func resetText(_ window: CodexBarEntry.Window) -> String? {
            guard let iso = window.resetsAt,
                let date = ISO8601DateFormatter().date(from: iso)
            else { return window.resetDescription }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "M/d HH:mm"
            return formatter.string(from: date) + " 리셋"
        }

        /// 창 길이로 이름을 붙인다. 예전엔 10080분(7일)만 "주간"으로 알아보고 나머지는
        /// fallback으로 흘려서, Codex의 43200분(30일) 한도가 "세션"으로 표시됐다.
        func label(for window: CodexBarEntry.Window, fallback: String) -> String {
            guard let minutes = window.windowMinutes else { return fallback }
            switch minutes {
            case ..<600: return "세션"  // 5~10시간짜리 롤링 윈도우
            case ..<20160: return "주간"  // 7일
            default: return "월간"  // 30일 이상
            }
        }

        if let p = entry.usage.primary {
            windows.append(
                .init(
                    label: label(for: p, fallback: "세션"), usedPercent: p.usedPercent,
                    resetText: resetText(p)))
        }
        if let s = entry.usage.secondary {
            windows.append(
                .init(
                    label: label(for: s, fallback: "주간"), usedPercent: s.usedPercent,
                    resetText: resetText(s)))
        }
        for extra in entry.usage.extraRateWindows ?? [] where extra.window.usedPercent > 0 {
            windows.append(
                .init(
                    label: extra.title, usedPercent: extra.window.usedPercent,
                    resetText: resetText(extra.window)))
        }

        return ProviderUsage(
            provider: entry.provider, plan: entry.usage.loginMethod, windows: windows)
    }
}
