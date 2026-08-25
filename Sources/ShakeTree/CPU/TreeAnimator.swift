import AppKit
import QuartzCore

/// 메뉴바 버튼의 클릭 영역과 분리된 아이콘 전용 뷰. 레이어 애니메이션은
/// WindowServer가 처리하므로 앱 메인 스레드를 프레임마다 깨우지 않는다.
@MainActor
private final class TreeAnimationView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// CPU 사용률에 따라 흔들림의 진폭·속도를 바꾸는 메뉴바 나무 아이콘.
///
/// 종전 구현은 Timer에서 `NSStatusBarButton.image`를 10Hz로 교체해 버튼 셀과 메뉴바
/// 전체를 계속 다시 그렸다. 나무를 줄기·수관·상태점 레이어로 나누고 숫자 transform만
/// Core Animation에 넘겨, CPU 구간이나 색이 바뀔 때만 앱 코드가 실행되게 한다.
@MainActor
final class TreeAnimator {
    private let iconView: TreeAnimationView
    private let trunkLayer = CAShapeLayer()
    private let canopyLayer = CAShapeLayer()
    private let awakeBadgeLayer = CAShapeLayer()
    private var cpuBucket = 0
    private var awake = false
    private var warningLevel: UsageLevel = .normal
    private var suspended = false
    private var stopped = false

    private static let bucketCount = 10
    private static let sampleCount = 24
    private static let trunkAnimationKey = "ShakeTree.trunk-sway"
    private static let canopyAnimationKey = "ShakeTree.canopy-sway"
    private static let baseX: CGFloat = 14
    private static let baseY: CGFloat = 1.5
    private static let trunkTopY: CGFloat = 10

    init(button: NSStatusBarButton) {
        // 투명 이미지는 status item의 폭만 잡는다. 실제 나무는 독립 레이어가 그린다.
        let placeholder = NSImage(size: TreeIcon.canvas)
        placeholder.isTemplate = true
        button.image = placeholder
        button.imagePosition = .imageOnly

        let iconView = TreeAnimationView(frame: NSRect(origin: .zero, size: TreeIcon.canvas))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        self.iconView = iconView

        button.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: TreeIcon.canvas.width),
            iconView.heightAnchor.constraint(equalToConstant: TreeIcon.canvas.height),
            iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        configureLayers()
        iconView.onAppearanceChange = { [weak self] in self?.applyState() }
        applyState()
    }

    func update(cpuUsage: Double) {
        let clamped = min(max(cpuUsage, 0), 1)
        let rawBucket = sqrt(clamped) * Double(Self.bucketCount)
        let nextBucket = min(max(Int(rawBucket.rounded()), 0), Self.bucketCount)
        guard nextBucket != cpuBucket else { return }

        // 경계 근처의 작은 샘플 노이즈가 0.5초마다 애니메이션을 재시작하지 않게 한다.
        guard abs(rawBucket - Double(cpuBucket)) >= 0.75 else { return }
        cpuBucket = nextBucket
        applyState()
    }

    /// 잠들지 않기 활성 여부 — 아이콘 오른쪽 아래 표시 점.
    func setAwake(_ value: Bool) {
        guard awake != value else { return }
        awake = value
        applyState()
    }

    func setWarningLevel(_ level: UsageLevel) {
        guard warningLevel != level else { return }
        warningLevel = level
        applyState()
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value, !stopped else { return }
        suspended = value
        value ? removeAnimationsAndReset() : installCurrentAnimation()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        removeAnimationsAndReset()
        iconView.removeFromSuperview()
    }

    /// 회귀 테스트용. 실제 움직임을 담당하는 두 레이어 모두 애니메이션이 있어야 한다.
    var animatedLayerCountForDiagnostics: Int {
        [
            trunkLayer.animation(forKey: Self.trunkAnimationKey),
            canopyLayer.animation(forKey: Self.canopyAnimationKey),
        ].compactMap { $0 }.count
    }

    var canopyTranslationForDiagnostics: CGFloat {
        (canopyLayer.presentation() ?? canopyLayer).transform.m41
    }

    private func configureLayers() {
        guard let rootLayer = iconView.layer else { return }
        rootLayer.masksToBounds = false

        let bounds = CGRect(origin: .zero, size: TreeIcon.canvas)

        trunkLayer.bounds = bounds
        trunkLayer.anchorPoint = CGPoint(
            x: Self.baseX / TreeIcon.canvas.width,
            y: Self.baseY / TreeIcon.canvas.height)
        trunkLayer.position = CGPoint(x: Self.baseX, y: Self.baseY)
        trunkLayer.fillColor = nil
        trunkLayer.lineWidth = 3
        trunkLayer.lineCap = .round
        let trunkPath = CGMutablePath()
        trunkPath.move(to: CGPoint(x: Self.baseX, y: Self.baseY))
        trunkPath.addCurve(
            to: CGPoint(x: Self.baseX, y: Self.trunkTopY),
            control1: CGPoint(x: Self.baseX, y: Self.baseY + 4),
            control2: CGPoint(x: Self.baseX, y: Self.trunkTopY - 3))
        trunkLayer.path = trunkPath

        canopyLayer.frame = bounds
        let canopyPath = CGMutablePath()
        addCircle(to: canopyPath, cx: 14, cy: 12.5, radius: 5.5)
        addCircle(to: canopyPath, cx: 9.5, cy: 11.5, radius: 3.8)
        addCircle(to: canopyPath, cx: 18.5, cy: 11.5, radius: 3.8)
        addCircle(to: canopyPath, cx: 14, cy: 16.3, radius: 3.8)
        canopyLayer.path = canopyPath

        awakeBadgeLayer.frame = bounds
        let badgePath = CGMutablePath()
        addCircle(to: badgePath, cx: 25.5, cy: 3, radius: 2.3)
        awakeBadgeLayer.path = badgePath

        rootLayer.addSublayer(trunkLayer)
        rootLayer.addSublayer(canopyLayer)
        rootLayer.addSublayer(awakeBadgeLayer)
    }

    private func applyState() {
        guard !stopped else { return }
        let color = resolvedTint(for: warningLevel).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trunkLayer.strokeColor = color
        canopyLayer.fillColor = color
        awakeBadgeLayer.fillColor = color
        awakeBadgeLayer.isHidden = !awake
        CATransaction.commit()

        suspended ? removeAnimationsAndReset() : installCurrentAnimation()
    }

    private func installCurrentAnimation() {
        guard cpuBucket > 0 else {
            removeAnimationsAndReset()
            return
        }

        let sways = (0...Self.sampleCount).map { index -> CGFloat in
            let phase = CGFloat(index) / CGFloat(Self.sampleCount) * 2 * .pi
            return amplitude * (sin(phase) + 0.25 * sin(2 * phase))
        }
        let keyTimes = (0...Self.sampleCount).map {
            NSNumber(value: Double($0) / Double(Self.sampleCount))
        }
        let trunkHeight = Self.trunkTopY - Self.baseY
        let angles = sways.map { NSNumber(value: Double(atan($0 / trunkHeight))) }
        let translations = sways.map { NSNumber(value: Double($0)) }
        let duration = cycleDuration

        let trunkAnimation = makeAnimation(
            keyPath: "transform.rotation.z", values: angles, keyTimes: keyTimes,
            duration: duration)
        trunkLayer.add(trunkAnimation, forKey: Self.trunkAnimationKey)

        let canopyAnimation = makeAnimation(
            keyPath: "transform.translation.x", values: translations, keyTimes: keyTimes,
            duration: duration)

        // 타이머 콜백에서 애니메이션을 교체할 때도 추가 작업까지 확실히 커밋한다.
        // 제거/초기화만 먼저 커밋하면 status item은 첫 자세에 고정될 수 있다.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trunkLayer.removeAnimation(forKey: Self.trunkAnimationKey)
        canopyLayer.removeAnimation(forKey: Self.canopyAnimationKey)
        trunkLayer.transform = CATransform3DIdentity
        canopyLayer.transform = CATransform3DIdentity
        trunkLayer.add(trunkAnimation, forKey: Self.trunkAnimationKey)
        canopyLayer.add(canopyAnimation, forKey: Self.canopyAnimationKey)
        CATransaction.commit()
    }

    private func makeAnimation(
        keyPath: String, values: [NSNumber], keyTimes: [NSNumber], duration: TimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 15, maximum: 30, preferred: 24)
        return animation
    }

    private func removeAnimationsAndReset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trunkLayer.removeAnimation(forKey: Self.trunkAnimationKey)
        canopyLayer.removeAnimation(forKey: Self.canopyAnimationKey)
        trunkLayer.transform = CATransform3DIdentity
        canopyLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private var normalizedBucket: CGFloat {
        CGFloat(cpuBucket) / CGFloat(Self.bucketCount)
    }

    private var amplitude: CGFloat {
        0.6 + 5.9 * normalizedBucket
    }

    private var cycleDuration: TimeInterval {
        let frequency = 1.8 + 8.2 * Double(normalizedBucket)
        return 2 * .pi / frequency
    }

    private func resolvedTint(for level: UsageLevel) -> NSColor {
        var color = Theme.warningColor(for: level) ?? .labelColor
        iconView.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (Theme.warningColor(for: level) ?? .labelColor)
                .usingColorSpace(.deviceRGB) ?? .labelColor
        }
        return color
    }

    private func addCircle(
        to path: CGMutablePath, cx: CGFloat, cy: CGFloat, radius: CGFloat
    ) {
        path.addEllipse(
            in: CGRect(
                x: cx - radius, y: cy - radius,
                width: radius * 2, height: radius * 2))
    }
}
