import AppKit

/// 앱 아이콘(Finder/Dock/Alert에 쓰이는 큰 컬러 아이콘). 메뉴바의 단색 나무와 달리
/// 여기서는 실제 색을 입힌다. macOS가 알아서 둥근 사각형 마스크를 씌워주므로
/// 배경은 캔버스 전체를 채우는 사각 그라데이션으로 그린다.
enum AppIconArt {
    static let size = CGSize(width: 1024, height: 1024)

    static func draw() {
        let bg = NSGradient(
            starting: NSColor(calibratedRed: 0.53, green: 0.80, blue: 0.94, alpha: 1),
            ending: NSColor(calibratedRed: 0.74, green: 0.90, blue: 0.98, alpha: 1))!
        bg.draw(in: NSRect(origin: .zero, size: size), angle: 270)

        let trunkColor = NSColor(calibratedRed: 0.47, green: 0.32, blue: 0.21, alpha: 1)
        let canopy = NSColor(calibratedRed: 0.31, green: 0.61, blue: 0.34, alpha: 1)
        let canopyShade = NSColor(calibratedRed: 0.24, green: 0.51, blue: 0.28, alpha: 1)

        // 트렁크
        trunkColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 462, y: 150, width: 100, height: 300),
            xRadius: 44, yRadius: 44
        ).fill()

        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
        }

        // 수관 — 옆 두 덩이는 그림자 톤, 위/중앙은 밝은 톤으로 입체감
        circle(324, 470, 158, canopyShade)
        circle(700, 470, 158, canopyShade)
        circle(512, 560, 240, canopy)
        circle(512, 726, 178, canopy)
    }

    static func renderPNG(to url: URL) {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
