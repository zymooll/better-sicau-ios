import XCTest
@testable import Better_Sicau

final class LogStoreTests: XCTestCase {
    private func makeEntry(
        _ text: String,
        level: LogLevel = .info,
        category: LogCategory = .general,
        sensitive: [String: String] = [:],
        at timestamp: Date = Date()
    ) -> LogEntry {
        LogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: level,
            category: category,
            template: text,
            sensitive: sensitive,
            source: "LogStoreTests.swift:1"
        )
    }

    func testRingBufferEvictsOldestBeyondCapacity() async {
        let store = LogStore(capacity: 3)
        for index in 0..<5 {
            await store.append(makeEntry("entry-\(index)", at: Date(timeIntervalSince1970: Double(index))))
        }

        let entries = await store.snapshot()

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.template), ["entry-4", "entry-3", "entry-2"])
    }

    func testRedactedTextHidesSensitiveValues() {
        let entry = makeEntry("登录成功：{username}", sensitive: ["username": "20240001"])

        XCTAssertEqual(entry.redactedText, "登录成功：<redacted>")
        XCTAssertFalse(entry.redactedText.contains("20240001"))
        XCTAssertEqual(entry.fullText, "登录成功：20240001")
    }

    func testLongestPlaceholderReplacedFirst() {
        let entry = makeEntry("{name}/{nameFull}", sensitive: ["name": "A", "nameFull": "AB"])

        XCTAssertEqual(entry.fullText, "A/AB")
        XCTAssertEqual(entry.redactedText, "<redacted>/<redacted>")
    }

    func testSnapshotFiltersByLevelAndCategory() async {
        let store = LogStore(capacity: 10)
        await store.append(makeEntry("a", level: .info, category: .network))
        await store.append(makeEntry("b", level: .error, category: .network))
        await store.append(makeEntry("c", level: .error, category: .auth))
        await store.append(makeEntry("d", level: .debug, category: .auth))

        let errors = await store.snapshot(levels: [.error])
        XCTAssertEqual(errors.map(\.template), ["c", "b"])

        let authErrors = await store.snapshot(levels: [.error], category: .auth)
        XCTAssertEqual(authErrors.map(\.template), ["c"])

        let noFilter = await store.snapshot()
        XCTAssertEqual(noFilter.count, 4)
    }

    func testExportModesAndClear() async {
        let store = LogStore(capacity: 10)
        await store.append(makeEntry("登录成功：{username}", category: .auth, sensitive: ["username": "20240001"]))
        await store.append(makeEntry("普通信息", category: .general))

        let redacted = await store.export(includeSensitive: false)
        XCTAssertTrue(redacted.contains("<redacted>"))
        XCTAssertFalse(redacted.contains("20240001"))

        let full = await store.export(includeSensitive: true)
        XCTAssertTrue(full.contains("20240001"))
        XCTAssertFalse(full.contains("<redacted>"))

        await store.clear()
        let afterClear = await store.snapshot()
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testSnapshotReturnsNewestFirst() async {
        let store = LogStore(capacity: 10)
        await store.append(makeEntry("old", at: Date(timeIntervalSince1970: 1)))
        await store.append(makeEntry("new", at: Date(timeIntervalSince1970: 2)))

        let entries = await store.snapshot()

        XCTAssertEqual(entries.map(\.template), ["new", "old"])
    }
}
