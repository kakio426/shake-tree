import Dispatch

/// macOS 커널이 판단하는 실제 "메모리 압박" 상태 (Activity Monitor의 Memory Pressure
/// 그래프와 동일한 신호). RAM 사용량 %는 macOS가 남는 메모리를 파일 캐시로 적극 활용해서
/// 평소에도 90~100%를 유지하는 게 정상이라, 그 값만으로 경고를 주면 항상 빨간색이 되어버린다.
/// 진짜 문제(스왑 임박 등)를 나타내는 이 신호를 따로 써서 아이콘/메뉴 색을 결정한다.
@MainActor
final class MemoryPressureMonitor {
    private(set) var level: UsageLevel = .normal
    private var source: DispatchSourceMemoryPressure?

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.level = Self.level(from: source.data)
        }
        source.activate()
        self.source = source
    }

    private static func level(from data: DispatchSource.MemoryPressureEvent) -> UsageLevel {
        if data.contains(.critical) { return .critical }
        if data.contains(.warning) { return .warning }
        return .normal
    }
}
