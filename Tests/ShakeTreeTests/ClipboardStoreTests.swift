import Foundation
import XCTest

@testable import ShakeTree

@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testStoreSerializesWritesAndPreservesOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakeTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ClipboardStore(databaseURL: directory.appendingPathComponent("clipboard.sqlite"))
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        let addedFirst = await store.add(
            kind: .text, text: "first", imageData: nil, createdAt: firstDate)
        let addedSecond = await store.add(
            kind: .text, text: "second", imageData: nil, createdAt: secondDate)
        XCTAssertTrue(addedFirst)
        XCTAssertTrue(addedSecond)

        var items = await store.items()
        XCTAssertEqual(items.map(\.text), ["second", "first"])

        // 중복 내용은 새 행을 만들지 않고 캡처 시각만 갱신한다.
        let movedFirst = await store.add(
            kind: .text, text: "first", imageData: nil,
            createdAt: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(movedFirst)
        items = await store.items()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.text), ["first", "second"])

        let pinned = await store.setPinned(true, id: items[1].id)
        let cleared = await store.deleteAllUnpinned()
        XCTAssertTrue(pinned)
        XCTAssertTrue(cleared)
        items = await store.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "second")
        XCTAssertTrue(items[0].pinned)
    }
}
