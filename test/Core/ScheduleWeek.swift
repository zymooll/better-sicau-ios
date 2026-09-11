import Foundation

/// A parsed teaching-week constraint extracted from a schedule's `weeks` text.
struct ScheduleWeekSpec: Equatable, Sendable {
    var ranges: [ClosedRange<Int>] = []
    var singleWeeks: [Int] = []
    var oddOnly = false
    var evenOnly = false

    var isEmpty: Bool { ranges.isEmpty && singleWeeks.isEmpty }

    func contains(_ week: Int) -> Bool {
        guard week > 0 else { return false }

        let parityMatches: Bool
        if oddOnly {
            parityMatches = !week.isMultiple(of: 2)
        } else if evenOnly {
            parityMatches = week.isMultiple(of: 2)
        } else {
            parityMatches = true
        }
        guard parityMatches else { return false }

        if isEmpty { return true }
        if ranges.contains(where: { $0.contains(week) }) { return true }
        return singleWeeks.contains(week)
    }
}

enum ScheduleWeek {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Teaching begins on the first Monday on or after the configured date.
    /// A Sunday registration date therefore maps to the following Monday.
    static func teachingMonday(_ date: Date, calendar: Calendar = ScheduleWeek.calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        return calendar.date(byAdding: .day, value: (9 - weekday) % 7, to: start) ?? start
    }

    static func date(startDate: Date, week: Int, day: Int) -> Date? {
        calendar.date(byAdding: .day, value: (week - 1) * 7 + day - 1, to: teachingMonday(startDate))
    }

    /// Parses common week expressions such as `1-16周`, `1-8,10-16周`,
    /// `单周`, `双周`, and `3-18周(单)`. Unconstrained or unparseable
    /// input is treated as "every week" so courses are never hidden by mistake.
    static func parse(_ raw: String) -> ScheduleWeekSpec {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ScheduleWeekSpec() }

        var ranges: [ClosedRange<Int>] = []
        var singleWeeks: [Int] = []
        let fullRange = NSRange(location: 0, length: text.utf16.count)

        if let rangeRegex = try? NSRegularExpression(pattern: #"(\d{1,2})\s*[-~–—～至]\s*(\d{1,2})"#) {
            for match in rangeRegex.matches(in: text, range: fullRange) {
                guard match.numberOfRanges >= 3,
                      let lowerRange = Range(match.range(at: 1), in: text),
                      let upperRange = Range(match.range(at: 2), in: text),
                      let lower = Int(text[lowerRange]),
                      let upper = Int(text[upperRange]),
                      upper >= lower else { continue }
                ranges.append(lower...upper)
            }
        }

        // Standalone week numbers are any digits that are not part of a range.
        let tokens = numbers(in: text)
        let rangeNumbers = ranges.flatMap { [$0.lowerBound, $0.upperBound] }
        let standalone = tokens.filter { !rangeNumbers.contains($0) }
        for number in standalone {
            if !singleWeeks.contains(number) { singleWeeks.append(number) }
        }
        singleWeeks.sort()
        ranges.sort { $0.lowerBound < $1.lowerBound }

        let oddOnly = text.contains("单") && !text.contains("双")
        let evenOnly = text.contains("双") && !text.contains("单")
        return ScheduleWeekSpec(ranges: ranges, singleWeeks: singleWeeks, oddOnly: oddOnly, evenOnly: evenOnly)
    }

    static func containsWeek(_ raw: String, week: Int) -> Bool {
        parse(raw).contains(week)
    }

    /// The start date for a term as local midnight, supporting common formats.
    static func parseStartDate(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let normalized = value.replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: "/", with: "-")
        guard normalized.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = normalized.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { return nil }
        return date
    }

    /// The 1-based teaching week for a date, derived from a term start date.
    /// Returns `nil` when the start date is missing, unparseable, or in the future.
    static func currentWeek(startDateText: String, now: Date = .now, calendar: Calendar = ScheduleWeek.calendar) -> Int? {
        guard let startDate = parseStartDate(startDateText) else { return nil }
        let startDay = teachingMonday(startDate, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        guard let days = calendar.dateComponents([.day], from: startDay, to: today).day, days >= 0 else { return nil }
        return min(days / 7 + 1, 52)
    }

    /// The highest week referenced by any schedule item, used to keep the
    /// overview selector within a sensible range. Falls back to 20.
    static func maximumWeek(in items: [ScheduleItem]) -> Int {
        let maximum = items.map { parse($0.weeks) }
            .flatMap { $0.ranges.map(\.upperBound) + $0.singleWeeks }
            .max() ?? 20
        return min(max(maximum, 20), 52)
    }

    /// Extracts a date from common exam-time strings such as
    /// `2026-06-20 09:00`, `2026/6/20 9:00-11:00`, or `2026年6月20日`.
    static func parseExamDate(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        guard let dateRange = firstRange(of: #"\d{4}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}"#, in: value) else { return nil }
        var candidate = String(value[dateRange])
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "日", with: "")
            .filter { !$0.isWhitespace }

        if let timeRange = firstRange(of: #"\d{1,2}:\d{2}"#, in: value) {
            candidate += " " + String(value[timeRange])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        for format in ["yyyy-M-d HH:mm", "yyyy-M-d"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: candidate) { return date }
        }
        return nil
    }

    /// A term's exam window: one week before its start date through one week
    /// after the following term's start date. Without a following term, a
    /// 26-week window is used as a fallback.
    static func termWindow(startDate: Date, nextStartDate: Date?, calendar: Calendar = ScheduleWeek.calendar) -> Range<Date>? {
        guard let lower = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: startDate)) else { return nil }

        let upper: Date
        if let nextStartDate {
            guard let candidate = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: nextStartDate)) else { return nil }
            upper = candidate
        } else {
            guard let candidate = calendar.date(byAdding: .weekOfYear, value: 26, to: startDate) else { return nil }
            upper = candidate
        }
        return lower..<upper
    }

    private static func numbers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})(?!\d)"#) else { return [] }
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
    }

    private static func firstRange(of pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return Range(match.range, in: text)
    }
}

extension ScheduleItem {
    var weekSpec: ScheduleWeekSpec { ScheduleWeek.parse(weeks) }

    /// Whether this item occurs during the given 1-based teaching week.
    func isActive(inWeek week: Int) -> Bool {
        ScheduleWeek.containsWeek(weeks, week: week)
    }
}

extension ExamItem {
    /// The parsed exam date when `time` carries a recognizable date string.
    var parsedDate: Date? {
        ScheduleWeek.parseExamDate(time)
    }

    /// Sorts exams by their real date. Items without a parseable date keep
    /// their relative order and go last, so no exam is silently reordered
    /// when the upstream format changes.
    static func sortedByDate(_ exams: [ExamItem]) -> [ExamItem] {
        exams.enumerated().sorted { lhs, rhs in
            switch (lhs.element.parsedDate, rhs.element.parsedDate) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
