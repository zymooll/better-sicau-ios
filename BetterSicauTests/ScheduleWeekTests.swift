import XCTest
@testable import Better_Sicau

final class ScheduleWeekTests: XCTestCase {
    // MARK: - parse

    func testParseRange() {
        let spec = ScheduleWeek.parse("1-16周")
        XCTAssertEqual(spec.ranges, [1...16])
        XCTAssertTrue(spec.singleWeeks.isEmpty)
        XCTAssertFalse(spec.oddOnly)
        XCTAssertFalse(spec.evenOnly)
    }

    func testParseMixedRangesAndSingles() {
        let spec = ScheduleWeek.parse("1-8,10,12-16周")
        XCTAssertEqual(spec.ranges, [1...8, 12...16])
        XCTAssertEqual(spec.singleWeeks, [10])
    }

    func testParseOddAndEven() {
        let odd = ScheduleWeek.parse("3-18周(单)")
        XCTAssertEqual(odd.ranges, [3...18])
        XCTAssertTrue(odd.oddOnly)
        XCTAssertFalse(odd.evenOnly)

        let even = ScheduleWeek.parse("双周")
        XCTAssertTrue(even.isEmpty)
        XCTAssertTrue(even.evenOnly)
    }

    func testUnparseableInputMeansEveryWeek() {
        let spec = ScheduleWeek.parse("待定")
        XCTAssertTrue(spec.isEmpty)
        XCTAssertFalse(spec.oddOnly)
        XCTAssertFalse(spec.evenOnly)
        XCTAssertTrue(spec.contains(7))
    }

    func testContainsHonorsParityAndRange() {
        let odd = ScheduleWeek.parse("1-16周(单)")
        XCTAssertTrue(odd.contains(1))
        XCTAssertFalse(odd.contains(2))
        XCTAssertFalse(odd.contains(17))
    }

    func testContainsWeekZeroIsFalse() {
        XCTAssertFalse(ScheduleWeek.parse("").contains(0))
    }

    // MARK: - currentWeek

    func testCurrentWeekCountsFromStartDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!

        // 2026-03-01 是周日 → 3月11日 是第 2 周
        let week = ScheduleWeek.currentWeek(
            startDateText: "2026-03-01",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(week, 2)
    }

    func testCurrentWeekNilWhenStartDateInFuture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!

        XCTAssertNil(ScheduleWeek.currentWeek(startDateText: "2026-03-01", now: now, calendar: calendar))
    }

    func testCurrentWeekNilForUnparseableStartDate() {
        XCTAssertNil(ScheduleWeek.currentWeek(startDateText: "开学待定"))
    }

    // MARK: - maximumWeek

    func testMaximumWeekUsesHighestReferencedWeek() {
        let items = [
            ScheduleItem(course: "A", weeks: "1-16周"),
            ScheduleItem(course: "B", weeks: "3-20周"),
        ]
        XCTAssertEqual(ScheduleWeek.maximumWeek(in: items), 20)
    }

    func testMaximumWeekFallsBackToTwenty() {
        XCTAssertEqual(ScheduleWeek.maximumWeek(in: []), 20)
    }

    // MARK: - parseStartDate

    func testParseStartDateSupportsFormats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!

        for text in ["2026-03-01", "2026/3/1", "2026年3月1日"] {
            XCTAssertEqual(ScheduleWeek.parseStartDate(text), expected, "failed: \(text)")
        }
        XCTAssertNil(ScheduleWeek.parseStartDate(""))
        XCTAssertNil(ScheduleWeek.parseStartDate("开学"))
    }

    // MARK: - parseExamDate

    func testParseExamDateSupportsFormats() {
        let iso = ScheduleWeek.parseExamDate("2026-06-20 09:00")
        XCTAssertNotNil(iso)
        let slash = ScheduleWeek.parseExamDate("2026/6/20 9:00-11:00")
        XCTAssertNotNil(slash)
        let chinese = ScheduleWeek.parseExamDate("2026年6月20日")
        XCTAssertNotNil(chinese)
        XCTAssertNil(ScheduleWeek.parseExamDate("时间待定"))
        XCTAssertNil(ScheduleWeek.parseExamDate(""))
    }

    func testParseExamDateTimeComponentWins() {
        let withTime = ScheduleWeek.parseExamDate("2026-06-20 14:30-16:00")
        let withoutTime = ScheduleWeek.parseExamDate("2026-06-20")
        XCTAssertNotNil(withTime)
        XCTAssertNotNil(withoutTime)
        XCTAssertGreaterThan(withTime!, withoutTime!)
    }

    // MARK: - termWindow

    func testTermWindowBounds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let next = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!

        let window = ScheduleWeek.termWindow(startDate: start, nextStartDate: next, calendar: calendar)
        XCTAssertNotNil(window)

        // 开学前 7 天 … 下学期开学后 7 天
        let lower = calendar.date(from: DateComponents(year: 2026, month: 2, day: 22))!
        let upper = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        XCTAssertEqual(window?.lowerBound, lower)
        XCTAssertEqual(window?.upperBound, upper)
    }

    func testTermWindowFallbackWithoutNextTerm() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!

        let window = ScheduleWeek.termWindow(startDate: start, nextStartDate: nil, calendar: calendar)
        XCTAssertNotNil(window)
        let upper = calendar.date(byAdding: .weekOfYear, value: 26, to: start)
        XCTAssertEqual(window?.upperBound, upper)
    }
    func testSundayRegistrationMapsToMondayColumn() throws {
        let start = try XCTUnwrap(ScheduleWeek.parseStartDate("2026-03-01"))
        let monday = try XCTUnwrap(ScheduleWeek.date(startDate: start, week: 1, day: 1))
        XCTAssertEqual(ScheduleWeek.calendar.component(.weekday, from: monday), 2)
        XCTAssertEqual(ScheduleWeek.calendar.component(.day, from: monday), 2)
        let nextMonday = try XCTUnwrap(ScheduleWeek.parseStartDate("2026-03-09"))
        XCTAssertEqual(ScheduleWeek.currentWeek(startDateText: "2026-03-01", now: nextMonday), 2)
    }

    func testInvalidDatesAreRejectedWithoutRollover() {
        XCTAssertNil(ScheduleWeek.parseStartDate("2026-02-30"))
        XCTAssertNil(ScheduleWeek.parseStartDate("2026-13-01"))
        XCTAssertNil(ScheduleWeek.parseStartDate("2026-00-01"))
        XCTAssertNotNil(ScheduleWeek.parseStartDate("2028-02-29"))
    }

    func testOverlappingCoursesRemainInOneAccessibleGroup() {
        let first = ScheduleItem(course: "A", dayOfWeek: 1, sectionStart: 1, sectionEnd: 2)
        let second = ScheduleItem(course: "B", dayOfWeek: 1, sectionStart: 2, sectionEnd: 4)
        let separate = ScheduleItem(course: "C", dayOfWeek: 1, sectionStart: 5, sectionEnd: 6)
        let pending = ScheduleItem(course: "待定")
        let blocks = ScheduleLayout.blocks([first, second, separate, pending])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].items.map(\.course), ["A", "B"])
        XCTAssertEqual(blocks[0].end, 4)
        XCTAssertFalse(ScheduleLayout.canPlace(pending))
    }

    func testOddAndEvenArrangementsHaveDistinctIDs() {
        let odd = ScheduleItem(course: "A", dayOfWeek: 1, sectionStart: 1, weeks: "单周")
        let even = ScheduleItem(course: "A", dayOfWeek: 1, sectionStart: 1, weeks: "双周")
        XCTAssertNotEqual(odd.id, even.id)
        XCTAssertNotEqual(ExamItem(course: "A", term: "2025-2026-1").id, ExamItem(course: "A", term: "2025-2026-2").id)
    }

}
