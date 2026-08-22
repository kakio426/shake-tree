import AppKit

/// 앱을 활성화하지 않고도 키 입력을 받는 플로팅 패널.
/// 닫으면 포커스가 원래 앱으로 자연스럽게 돌아간다. 메인 패널과 클립보드
/// 히스토리 패널이 같은 외관·동작을 쓰도록 여기서 조립까지 맡는다.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 메뉴바 버튼 아래에 상단을 붙여 띄운다. 화면 밖으로는 넘치지 않게.
    func positionBelow(anchorButton: NSStatusBarButton?) {
        let size = frame.size
        let screen =
            anchorButton?.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x: CGFloat
        if let buttonFrame = anchorButton?.window?.frame {
            // 아이콘 중심에 패널을 맞추되 오른쪽 가장자리를 살짝 넘어가지 않게
            x = buttonFrame.midX - size.width / 2
        } else {
            x = visible.maxX - size.width - 8
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(NSPoint(x: x, y: visible.maxY - size.height))
    }

    /// 열려 있는 상태에서 높이만 내용에 맞춘다. 상단(메뉴바)은 고정.
    func resizeKeepingTop(to height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var newFrame = frame
        newFrame.origin.y += newFrame.height - height
        newFrame.size.height = height
        setFrame(newFrame, display: true)
    }

    /// 두 패널이 동일한 팝오버 스타일(비활성화 가능 + 테두리 없음 + 그림자)을 쓰도록 공통 조립.
    @MainActor
    static func makePopover(contentView: NSView, width: CGFloat) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 10),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = contentView
        return panel
    }
}
