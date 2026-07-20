/// CPU/디스크 경고 수준 판정을 한 곳에서 관리 — 메뉴 드롭다운 색상과 메뉴바 아이콘 색상이
/// 서로 다른 곳에서 각자 기준을 매기다 어긋나는 일이 없도록 공용으로 둔다.
/// RAM은 사용량 %가 항상 90~100%를 유지하는 게 정상(macOS가 유휴 메모리를 파일 캐시로
/// 적극 씀)이라 % 기준 경고가 무의미해서, 대신 MemoryPressureMonitor의 커널 압박 신호를
/// 그대로 쓴다.
enum UsageLevel: Sendable {
    case normal
    case warning
    case critical
}

enum SystemThresholds {
    static func cpuLevel(_ fraction: Double) -> UsageLevel {
        switch fraction {
        case 0.95...: return .critical
        case 0.80..<0.95: return .warning
        default: return .normal
        }
    }

    /// 디스크는 꽉 차기 직전에만 경고 — 일상적으로 60~80%는 흔하다.
    static func diskLevel(_ fraction: Double) -> UsageLevel {
        switch fraction {
        case 0.95...: return .critical
        case 0.88..<0.95: return .warning
        default: return .normal
        }
    }

    /// 둘 중 더 심각한 쪽 — 아이콘 색은 하나만 고를 수 있으므로.
    static func worse(_ a: UsageLevel, _ b: UsageLevel) -> UsageLevel {
        switch (a, b) {
        case (.critical, _), (_, .critical): return .critical
        case (.warning, _), (_, .warning): return .warning
        default: return .normal
        }
    }
}
