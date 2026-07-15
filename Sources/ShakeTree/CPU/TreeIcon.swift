import AppKit

/// 메뉴바용 나무 아이콘. 트렁크는 아래가 고정되고 위(수관)가 sway만큼 휘어진다.
/// sway 값은 애니메이터가 CPU 사용률(바람 세기)에 따라 실시간으로 흔든다.
/// 템플릿 이미지라 라이트/다크 메뉴바에 자동 대응.
enum TreeIcon {
    static let canvas = NSSize(width: 28, height: 20)
    private static let baseX: CGFloat = 14
    private static let baseY: CGFloat = 1.5

    /// tint가 nil이면 평소처럼 흑백 템플릿 이미지(라이트/다크 메뉴바에 자동 대응).
    /// tint를 주면 그 색을 실제로 칠한 컬러 이미지가 된다 — 템플릿 이미지는 시스템이
    /// 항상 강제로 흑백 처리하므로, 색을 보여주려면 템플릿을 꺼야 한다. CPU/RAM이
    /// 경고 수준일 때만 이 경로를 타도록 해서 평소엔 깔끔한 흑백을 유지한다.
    @MainActor
    static func image(sway: CGFloat, awake: Bool = false, tint: NSColor? = nil) -> NSImage {
        let img = NSImage(size: canvas, flipped: false) { _ in
            (tint ?? NSColor.black).set()
            draw(sway: sway, awake: awake)
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }

    /// sway: 수관의 수평 변위(pt). 양수 = 오른쪽으로 휘어짐.
    /// awake: 잠들지 않기 활성 시 오른쪽 아래에 작은 표시 점을 찍는다.
    static func draw(sway: CGFloat, awake: Bool = false) {
        // 트렁크: 아래는 제자리, 위로 갈수록 sway를 따라 휘어지는 2차 곡선
        let topX = baseX + sway
        let topY: CGFloat = 10
        let trunk = NSBezierPath()
        trunk.move(to: NSPoint(x: baseX, y: baseY))
        trunk.curve(
            to: NSPoint(x: topX, y: topY),
            controlPoint1: NSPoint(x: baseX + sway * 0.1, y: baseY + 4),
            controlPoint2: NSPoint(x: baseX + sway * 0.55, y: topY - 3))
        trunk.lineWidth = 3
        trunk.lineCapStyle = .round
        trunk.stroke()

        // 수관: 겹친 원들의 뭉게구름, 중심이 sway를 따라 이동
        let cx = baseX + sway
        let cy: CGFloat = 12.5
        circle(cx: cx, cy: cy, r: 5.5)
        circle(cx: cx - 4.5, cy: cy - 1, r: 3.8)
        circle(cx: cx + 4.5, cy: cy - 1, r: 3.8)
        circle(cx: cx, cy: cy + 3.8, r: 3.8)

        // 잠들지 않기 활성 표시 — 흔들리는 수관과 겹치지 않는 오른쪽 아래 구석에 점
        if awake {
            circle(cx: 25.5, cy: 3, r: 2.3)
        }
    }

    /// 경고색 미리보기 PNG (디자인 확인용)
    static func dumpWarningColors(to dir: String) {
        let dirURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let cases: [(String, NSColor?)] = [
            ("normal", nil), ("warning", .systemOrange), ("critical", .systemRed),
        ]
        for (name, color) in cases {
            writePNG(sway: 0, tint: color, to: dirURL.appendingPathComponent("\(name).png"))
        }
        print("wrote warning color previews to \(dir)")
    }

    private static func circle(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
    }

    /// 산들바람/태풍 흔들림 사이클을 각각 프레임으로 저장 (움직임 확인용)
    static func dump(to dir: String) {
        let dirURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        // (접두사, 진폭) — 애니메이터의 sway 계산과 동일한 공식 사용
        let cases: [(String, CGFloat)] = [("breeze", 2.0), ("typhoon", 6.5)]
        let frames = 8
        for (prefix, amp) in cases {
            for i in 0..<frames {
                let t = CGFloat(i) / CGFloat(frames) * .pi * 2
                let sway = amp * (sin(t) + 0.25 * sin(2.3 * t))
                writePNG(sway: sway, to: dirURL.appendingPathComponent("\(prefix)\(i).png"))
            }
        }
        // 잠들지 않기 배지 확인용
        writePNG(sway: 0, awake: false, to: dirURL.appendingPathComponent("awake_off.png"))
        writePNG(sway: 0, awake: true, to: dirURL.appendingPathComponent("awake_on.png"))
        print("wrote breeze/typhoon cycles + awake badge to \(dir)")
    }

    private static func writePNG(sway: CGFloat, awake: Bool = false, tint: NSColor? = nil, to url: URL) {
        let scale = 14
        let w = Int(canvas.width) * scale
        let h = Int(canvas.height) * scale
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(scale))
        transform.concat()
        (tint ?? NSColor.black).set()
        draw(sway: sway, awake: awake)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
