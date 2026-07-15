import AppKit

/// 나무를 바람에 흔든다. CPU 사용률이 높을수록 진폭·주파수가 커져
/// 산들바람(작게 살랑) → 태풍(크게 요동) 으로 변한다.
/// 프레임을 미리 만들지 않고 매 틱마다 sway 값을 계산해 다시 그린다.
@MainActor
final class TreeAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private let interval: TimeInterval = 0.07

    private var phase: CGFloat = 0
    // 목표값 (CPU에 따라 갱신) 과 현재 표시값 (부드럽게 따라감)
    private var targetAmplitude: CGFloat = 1.5
    private var targetFrequency: CGFloat = 2.0
    private var amplitude: CGFloat = 1.5
    private var frequency: CGFloat = 2.0
    private var awake = false
    private var warningColor: NSColor?

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = TreeIcon.image(sway: 0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
        awake = value
    }

    /// nil이면 평소 흑백, 색을 주면 그 색으로 칠한다 — CPU/RAM 경고 시에만 호출할 것.
    func setWarningColor(_ color: NSColor?) {
        warningColor = color
    }

    private func tick() {
        // 목표값으로 보간하되, CPU 샘플링이 0.5초마다 갱신되므로 그 안에서
        // 충분히 따라잡을 수 있도록 이전보다 반응성을 높였다 (0.08 → 0.12).
        amplitude += (targetAmplitude - amplitude) * 0.12
        frequency += (targetFrequency - frequency) * 0.12

        phase += frequency * CGFloat(interval)
        if phase > .pi * 2 { phase -= .pi * 2 }

        // 기본 진동에 약한 2차 하모닉을 더해 덜 기계적인 바람 흔들림
        let sway = amplitude * (sin(phase) + 0.25 * sin(2.3 * phase))
        button?.image = TreeIcon.image(sway: sway, awake: awake, tint: warningColor)
    }
}
