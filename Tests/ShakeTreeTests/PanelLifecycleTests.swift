import AppKit
import XCTest

@testable import ShakeTree

@MainActor
final class PanelLifecycleTests: XCTestCase {
    func testMainPanelReleasesHostingViewWhenClosed() {
        _ = NSApplication.shared
        let model = AppModel(keepAwake: KeepAwake())
        let controller = MainPanelController(model: model)
        var visibility: [Bool] = []
        controller.onVisibilityChange = { visibility.append($0) }

        for _ in 0..<5 {
            controller.show()
            XCTAssertTrue(controller.hasLoadedPanel)

            controller.close()
            XCTAssertFalse(controller.hasLoadedPanel)
        }
        XCTAssertEqual(visibility, Array(repeating: [true, false], count: 5).flatMap { $0 })

        // 중복 close가 상태 알림이나 해제 동작을 다시 수행하지 않아야 한다.
        controller.close()
        XCTAssertEqual(visibility, Array(repeating: [true, false], count: 5).flatMap { $0 })
    }

    func testSystemSnapshotStartsEmpty() {
        XCTAssertEqual(SystemSnapshot.empty.cpuFraction, 0)
        XCTAssertTrue(SystemSnapshot.empty.cpuHistory.isEmpty)
        XCTAssertTrue(SystemSnapshot.empty.memHistory.isEmpty)
        XCTAssertEqual(SystemSnapshot.empty.memLevel, .normal)
    }

    func testFloatingPanelRejectsInvalidHeight() {
        _ = NSApplication.shared
        let panel = FloatingPanel.makePopover(contentView: NSView(), width: 320)
        let originalFrame = panel.frame
        panel.resizeKeepingTop(to: .nan)
        XCTAssertEqual(panel.frame, originalFrame)
        panel.close()
    }
}
