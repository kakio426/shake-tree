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
                task.arguments = ["usage", "--provider", "both", "--json"]
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
        return try JSONDecoder().decode([CodexBarEntry].self, from: data)
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

        func label(for window: CodexBarEntry.Window, fallback: String) -> String {
            guard let minutes = window.windowMinutes else { return fallback }
            switch minutes {
            case ..<600: return "세션"
            case 10080: return "주간"
            default: return fallback
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
