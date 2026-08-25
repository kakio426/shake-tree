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

        weak var releasedHost: NSView?
        for _ in 0..<5 {
            autoreleasepool {
                controller.show()
                XCTAssertTrue(controller.hasLoadedPanel)
                releasedHost = controller.hostedViewForDiagnostics
                XCTAssertNotNil(releasedHost)

                controller.close()
                XCTAssertFalse(controller.hasLoadedPanel)
            }
            // AppKit/SwiftUI가 현재 트랜잭션 끝에서 보유 참조를 정리할 시간을 준다.
            for _ in 0..<10 where releasedHost != nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertNil(releasedHost, "닫힌 패널의 NSHostingView가 실제로 해제되어야 합니다")
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

    func testPanelHeightConvergenceSuppressesTwoCycleUntilContentChanges() {
        var convergence = PanelHeightConvergence()

        XCTAssertEqual(convergence.resolve(300), 300)
        XCTAssertEqual(convergence.resolve(302), 302)
        XCTAssertEqual(convergence.resolve(300), 300)
        XCTAssertEqual(convergence.resolve(302), 302)
        XCTAssertEqual(convergence.suppressedRange, 300...302)

        XCTAssertNil(convergence.resolve(300))
        XCTAssertNil(convergence.resolve(302))

        // 실제 콘텐츠 높이가 범위를 벗어나면 억제를 풀고 새 높이를 반영한다.
        XCTAssertEqual(convergence.resolve(340), 340)
        XCTAssertNil(convergence.suppressedRange)
    }

    func testTreeAnimatorUsesCompositorLayersAndSuspendsCleanly() throws {
        _ = NSApplication.shared
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let button = try XCTUnwrap(statusItem.button)
        let animator = TreeAnimator(button: button)
        animator.update(cpuUsage: 1)
        XCTAssertEqual(animator.animatedLayerCountForDiagnostics, 2)

        var positions: [CGFloat] = []
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            positions.append(animator.canopyTranslationForDiagnostics)
        }
        XCTAssertGreaterThan(
            (positions.max() ?? 0) - (positions.min() ?? 0), 0.1,
            "레이어 애니메이션의 presentation 값이 실제로 진행되어야 합니다")

        // CPU 구간 변경으로 애니메이션을 교체한 뒤에도 첫 자세에 고정되지 않아야 한다.
        animator.update(cpuUsage: 0.1)
        positions.removeAll()
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            positions.append(animator.canopyTranslationForDiagnostics)
        }
        XCTAssertGreaterThan(
            (positions.max() ?? 0) - (positions.min() ?? 0), 0.1,
            "CPU 구간 변경 뒤에도 presentation 값이 계속 진행되어야 합니다")

        animator.setSuspended(true)
        XCTAssertEqual(animator.animatedLayerCountForDiagnostics, 0)

        animator.setSuspended(false)
        XCTAssertEqual(animator.animatedLayerCountForDiagnostics, 2)

        animator.stop()
        XCTAssertEqual(animator.animatedLayerCountForDiagnostics, 0)
    }
}
