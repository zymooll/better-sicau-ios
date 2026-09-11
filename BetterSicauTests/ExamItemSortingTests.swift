import XCTest
@testable import Better_Sicau

final class ExamItemSortingTests: XCTestCase {
    func testSortsMixedDateFormatStringsByRealDate() {
        let items = [
            ExamItem(course: "A", time: "2026-06-20 09:00"),
            ExamItem(course: "B", time: "2026年6月19日"),
            ExamItem(course: "C", time: "2026/6/21 14:30-16:00"),
        ]

        let sorted = ExamItem.sortedByDate(items)

        XCTAssertEqual(sorted.map(\.course), ["B", "A", "C"])
    }

    func testUnparseableDatesGoLastKeepingRelativeOrder() {
        let items = [
            ExamItem(course: "X", time: "时间待定"),
            ExamItem(course: "A", time: "2026-06-20 09:00"),
            ExamItem(course: "Y", time: "见教务处通知"),
        ]

        let sorted = ExamItem.sortedByDate(items)

        XCTAssertEqual(sorted.map(\.course), ["A", "X", "Y"])
    }

    func testSameDateKeepsStableRelativeOrder() {
        let items = [
            ExamItem(course: "A", time: "2026-06-20 09:00"),
            ExamItem(course: "B", time: "2026年6月20日 10:00"),
        ]

        let sorted = ExamItem.sortedByDate(items)

        XCTAssertEqual(sorted.map(\.course), ["A", "B"])
    }

    func testParsedDateHandlesSupportedFormats() {
        XCTAssertNotNil(ExamItem(time: "2026-06-20 09:00").parsedDate)
        XCTAssertNotNil(ExamItem(time: "2026/6/20 9:00-11:00").parsedDate)
        XCTAssertNotNil(ExamItem(time: "2026年6月20日").parsedDate)
        XCTAssertNil(ExamItem(time: "待定").parsedDate)
        XCTAssertNil(ExamItem(time: "").parsedDate)
    }
}
