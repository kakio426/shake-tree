import AppKit

/// 나무를 바람에 흔든다. CPU 사용률이 높을수록 진폭·주파수가 커져
/// 산들바람(작게 살랑) → 태풍(크게 요동) 으로 변한다.
/// sway 값은 매 틱 계산하되 같은 0.25pt 프레임은 캐시해 메뉴바를 불필요하게 다시
/// 그리지 않는다.
@MainActor
final class TreeAnimator {
    private struct FrameKey: Hashable {
        let swayQuarterPoints: Int
        let awake: Bool
        let warningLevel: UsageLevel
    }

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    // 10fps면 28pt 메뉴바 아이콘의 움직임은 충분히 부드럽다. CPU에 따른 속도 차이는
    // phase 증가량으로 유지되므로 프레임 주기를 높이지 않아도 기능 표현은 같다.
    private let interval: TimeInterval = 0.1

    private var phase: CGFloat = 0
    // 목표값 (CPU에 따라 갱신) 과 현재 표시값 (부드럽게 따라감)
    private var targetAmplitude: CGFloat = 1.5
    private var targetFrequency: CGFloat = 2.0
    private var amplitude: CGFloat = 1.5
    private var frequency: CGFloat = 2.0
    private var awake = false
    private var warningLevel: UsageLevel = .normal
    private var currentSway: CGFloat = 0
    private var lastFrameKey: FrameKey?
    private var frameCache: [FrameKey: NSImage] = [:]
    private var suspended = false

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = TreeIcon.image(sway: 0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(cpuUsage: Double) {
        let c = min(max(cpuUsage, 0), 1)
        // CPU는 대부분 낮은~중간 구간(0~40%)에 머물기 때문에, 선형 대신 제곱근 곡선을
        // 써서 그 구간에서도 흔들림 변화가 뚜렷이 느껴지게 한다. 최댓값은 그대로 유지.
        let curved = sqrt(c)
        targetAmplitude = 1.0 + 5.5 * curved  // 1.0 ~ 6.5 pt
        targetFrequency = 1.8 + 8.2 * curved  // 1.8 ~ 10 rad/s
    }

    /// 잠들지 않기 활성 여부 — 아이콘에 표시 점을 붙인다
    func setAwake(_ value: Bool) {
        guard awake != value else { return }
        awake = value
        renderCurrentFrame()
    }

    func setWarningLevel(_ level: UsageLevel) {
        guard warningLevel != level else { return }
        warningLevel = level
        renderCurrentFrame()
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        timer?.fireDate = value ? .distantFuture : Date()
        if !value { tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frameCache.removeAll()
        lastFrameKey = nil
    }

    private func tick() {
        // 목표값으로 보간하되, CPU 샘플링이 0.5초마다 갱신되므로 그 안에서
        // 충분히 따라잡을 수 있도록 이전보다 반응성을 높였다 (0.08 → 0.12).
        amplitude += (targetAmplitude - amplitude) * 0.12
        frequency += (targetFrequency - frequency) * 0.12

        phase += frequency * CGFloat(interval)
        if phase > .pi * 2 { phase -= .pi * 2 }

        // 기본 진동에 약한 2차 하모닉을 더해 덜 기계적인 바람 흔들림
        currentSway = amplitude * (sin(phase) + 0.25 * sin(2.3 * phase))
        renderCurrentFrame()
    }

    private func renderCurrentFrame() {
        guard !suspended else { return }

        // 0.25pt 단위로 양자화하면 28pt 아이콘에서는 차이가 보이지 않으면서 같은 프레임을
        // 재사용할 수 있다. 같은 키가 연속되면 status item 자체도 다시 그리지 않는다.
        let swayQuarterPoints = Int((currentSway * 4).rounded())
        let key = FrameKey(
            swayQuarterPoints: swayQuarterPoints,
            awake: awake,
            warningLevel: warningLevel)
        guard key != lastFrameKey else { return }
        lastFrameKey = key

        if let cached = frameCache[key] {
            button?.image = cached
            return
        }

        let image = TreeIcon.image(
            sway: CGFloat(swayQuarterPoints) / 4,
            awake: awake,
            tint: Theme.warningColor(for: warningLevel))
        frameCache[key] = image
        button?.image = image
    }
}
