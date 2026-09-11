import Foundation

struct ScheduleBlock: Identifiable {
    var day: Int
    var start: Int
    var end: Int
    var items: [ScheduleItem]
    var id: String { RecordIdentity.make(items.map(\.id).sorted()) }
}

enum ScheduleLayout {
    static func canPlace(_ item: ScheduleItem) -> Bool {
        guard let day = item.dayOfWeek, (1...7).contains(day), let start = item.sectionStart else { return false }
        let end = item.sectionEnd ?? start
        return (1...24).contains(start) && end >= start && end <= 24
    }

    /// Merge connected overlapping intervals, preserving every underlying item.
    static func blocks(_ items: [ScheduleItem]) -> [ScheduleBlock] {
        var result: [ScheduleBlock] = []
        for day in 1...7 {
            let sorted = items.filter { canPlace($0) && $0.dayOfWeek == day }
                .sorted { ($0.sectionStart ?? 0, $0.id) < ($1.sectionStart ?? 0, $1.id) }
            var current: ScheduleBlock?
            for item in sorted {
                let start = item.sectionStart!
                let end = item.sectionEnd ?? start
                if var group = current, start <= group.end {
                    group.end = max(group.end, end)
                    group.items.append(item)
                    current = group
                } else {
                    if let current { result.append(current) }
                    current = ScheduleBlock(day: day, start: start, end: end, items: [item])
                }
            }
            if let current { result.append(current) }
        }
        return result
    }
}
