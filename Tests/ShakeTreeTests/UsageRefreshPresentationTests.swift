import AppKit
import SwiftUI
import XCTest
@testable import ShakeTree

@MainActor
final class UsageRefreshPresentationTests: XCTestCase {
    func testOvernightLoadingPresentationIsCompactAndHasNoUnsupportedCard() throws {
        _ = NSApplication.shared
        let now = Date()
        let window = ProviderUsage.WindowDisplay(id: "weekly", label: "1주일", group: nil,
            usedPercent: 52, resetsAt: now.addingTimeInterval(86400), resetDescription: nil)
        let codex = ProviderUsage(provider: "codex", plan: "pro", fetchedAt: now, windows: [window])
        var claude = ProviderUsage(provider: "claude", plan: "Pro", fetchedAt: now.addingTimeInterval(-86400), windows: [window])
        claude.refreshState = .loading(now.addingTimeInterval(-12))
        let url = try XCTUnwrap(Bundle.module.url(forResource: "antigravity-0.82", withExtension: "json", subdirectory: "Fixtures"))
        var antigravity = try XCTUnwrap(UsageProvider.decode(Data(contentsOf: url), provider: "antigravity", now: now).usage)
        antigravity.fetchedAt = now.addingTimeInterval(-86400)
        antigravity.refreshState = .queued
        var grok = ProviderUsage(provider: "grok", fetchedAt: now.addingTimeInterval(-86400), windows: [window])
        grok.refreshState = .queued
        let notice = ProviderUsage(provider: "gemini", issue: ProviderUsage.geminiMigrationNotice)
        let usages = [codex, claude, antigravity, notice, grok]
        XCTAssertEqual(UsageGridView.visibleUsages(usages).map(\.provider), ["codex", "claude", "antigravity", "grok"])
        XCTAssertFalse(claude.hasCurrentValues(at: now))
        XCTAssertFalse(antigravity.hasCurrentValues(at: now))
        let view = UsageGridView(usages: usages, isRefreshing: true)
            .padding(10).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThan(size.height, 440, "Overnight state must not expand every expired quota into repeated warnings")
        host.setFrameSize(size)
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let directory = ProcessInfo.processInfo.environment["SHAKETREE_QA_OUTPUT"] {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overnight-loading.png"))
        }
    }
}
