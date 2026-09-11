import SwiftUI

/// Fixed row/column headings share one scroll coordinate space with the cards.
struct ScheduleOverviewView: View {
    @ObservedObject var store: AppStore
    let searchText: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 86
    @State private var week = 1
    @State private var hasCustomWeek = false
    @State private var offset: CGPoint = .zero
    @State private var selectedBlock: ScheduleBlock?

    private let timeWidth: CGFloat = 38
    private let headerHeight: CGFloat = 48
    private var maximumWeek: Int { ScheduleWeek.maximumWeek(in: store.schedule) }
    private var currentWeek: Int? {
        guard store.isTodayInSelectedTerm, let week = store.currentTeachingWeek, week <= maximumWeek else { return nil }
        return week
    }
    private var items: [ScheduleItem] {
        store.schedule.filter { item in
            item.isActive(inWeek: week) && (searchText.isEmpty ||
                [item.course, item.teacher, item.location, item.weeks].joined(separator: " ")
                    .localizedCaseInsensitiveContains(searchText))
        }
    }
    private var blocks: [ScheduleBlock] { ScheduleLayout.blocks(items) }
    private var unplaced: [ScheduleItem] { items.filter { !ScheduleLayout.canPlace($0) } }
    private var lastSection: Int { max(12, blocks.map(\.end).max() ?? 12) }

    var body: some View {
        VStack(spacing: 0) {
            weekHeader
            Divider()
            if dynamicTypeSize.isAccessibilitySize {
                accessibleList
            } else if items.isEmpty {
                EmptyStateView(title: searchText.isEmpty ? "本周暂无课程" : "没有匹配的课程", systemImage: "calendar")
                    .frame(maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let dayWidth = max(104, (geometry.size.width - timeWidth) / 7)
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 16) {
                            if !blocks.isEmpty { grid(dayWidth: dayWidth) }
                            if !unplaced.isEmpty { pendingCourses.frame(width: geometry.size.width).offset(x: max(0, -offset.x)) }
                        }
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: ScheduleOffsetKey.self, value: CGPoint(x: content.frame(in: .global).minX - geometry.frame(in: .global).minX, y: content.frame(in: .global).minY - geometry.frame(in: .global).minY))
                            }
                        }
                    }
                    .coordinateSpace(name: "schedule-scroll")
                    .onPreferenceChange(ScheduleOffsetKey.self) { value in
                        if #available(iOS 18.0, *) {} else { offset = value }
                    }
                    .modifier(ScheduleScrollTracking(offset: $offset))
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { syncWeek() }
        .onChange(of: store.selectedTerm) { _, _ in hasCustomWeek = false; syncWeek() }
        .onChange(of: currentWeek) { _, _ in syncWeek() }
        .onChange(of: maximumWeek) { _, _ in week = min(week, maximumWeek) }
        .sheet(item: $selectedBlock) { block in
            ScheduleDetails(items: block.items)
        }
    }

    private var weekHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 32) }
                    .disabled(week <= 1).accessibilityLabel("上一周")
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Text("第 \(week) 周").font(.headline).monospacedDigit()
                    if let first = date(for: 1), let last = date(for: 7) {
                        Text("\(dateText(first)) — \(dateText(last))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("未设置教学日期").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 32) }
                    .disabled(week >= maximumWeek).accessibilityLabel("下一周")
            }
            HStack {
                Text("\(items.count) 项安排").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let currentWeek {
                    Button(currentWeek == week ? "本周" : "回到本周") {
                        hasCustomWeek = false
                        syncWeek()
                    }.font(.caption).disabled(currentWeek == week)
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("点击课程查看详情").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func grid(dayWidth: CGFloat) -> some View {
        let width = timeWidth + dayWidth * 7
        let height = headerHeight + CGFloat(lastSection) * rowHeight
        return ZStack(alignment: .topLeading) {
            ForEach(1...lastSection, id: \.self) { section in
                Rectangle().fill(Color.primary.opacity(0.08))
                    .frame(width: width, height: 1)
                    .offset(y: headerHeight + CGFloat(section) * rowHeight)
            }
            ForEach(0...7, id: \.self) { column in
                Rectangle().fill(Color.primary.opacity(0.08))
                    .frame(width: 1, height: height)
                    .offset(x: timeWidth + CGFloat(column) * dayWidth)
            }
            ForEach(blocks) { block in
                blockButton(block, dayWidth: dayWidth)
            }
            // Keep the section ruler visible while scrolling horizontally.
            VStack(spacing: 0) {
                Color.clear.frame(width: timeWidth, height: headerHeight)
                ForEach(1...lastSection, id: \.self) { section in
                    Text("\(section)").font(.caption).foregroundStyle(.secondary)
                        .frame(width: timeWidth, height: rowHeight)
                        .background(Color(uiColor: .systemBackground))
                }
            }
            .frame(width: timeWidth, height: height, alignment: .topLeading)
            .offset(x: max(0, -offset.x))
            // Keep weekday headings visible while scrolling vertically.
            HStack(spacing: 0) {
                Color.clear.frame(width: timeWidth, height: headerHeight)
                ForEach(1...7, id: \.self) { day in
                    VStack(spacing: 3) {
                        Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1])
                        Text(date(for: day).map { isToday($0) ? "今天" : dateText($0) } ?? "—")
                    }
                    .font(.caption)
                    .foregroundStyle(date(for: day).map(isToday) == true ? Color.sicauGreen : Color.primary)
                    .frame(width: dayWidth, height: headerHeight)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .frame(width: width, height: headerHeight, alignment: .topLeading)
            .offset(y: min(max(0, -offset.y), height - headerHeight))
            Text("节次").font(.caption2)
                .frame(width: timeWidth, height: headerHeight)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .offset(x: max(0, -offset.x), y: min(max(0, -offset.y), height - headerHeight))
        }
        .frame(width: width, height: height)
    }

    private func blockButton(_ block: ScheduleBlock, dayWidth: CGFloat) -> some View {
        let tint = Color.scheduleTint(forDay: block.day)
        return Button { selectedBlock = block } label: {
            VStack(alignment: .leading, spacing: 4) {
                if block.items.count > 1 {
                    Text("重叠 · \(block.items.count) 项").font(.caption.weight(.bold))
                    Text(block.items.map(\.course).joined(separator: " / ")).font(.caption).lineLimit(2)
                } else if let item = block.items.first {
                    Text(item.course).font(.caption.weight(.semibold)).lineLimit(2)
                    Text(item.location.isEmpty ? "地点待定" : item.location).font(.caption2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(8)
            .frame(width: dayWidth - 8, height: CGFloat(block.end - block.start + 1) * rowHeight - 8, alignment: .topLeading)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(block.items.map { "\($0.course)，\($0.displayDay)，\($0.displaySections)，\($0.location)" }.joined(separator: "；"))
        .accessibilityHint("打开课程详情")
        .offset(x: timeWidth + CGFloat(block.day - 1) * dayWidth + 4, y: headerHeight + CGFloat(block.start - 1) * rowHeight + 4)
    }

    private var pendingCourses: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间待定或自行安排").font(.headline)
            ForEach(unplaced) { item in
                Button {
                    selectedBlock = ScheduleBlock(day: 0, start: 0, end: 0, items: [item])
                } label: { ScheduleRow(item: item) }.buttonStyle(.plain)
            }
        }.padding()
    }

    private var accessibleList: some View {
        List {
            if items.isEmpty { Text("本周暂无匹配课程") }
            ForEach(items) { item in
                Button {
                    selectedBlock = ScheduleBlock(day: item.dayOfWeek ?? 0, start: 0, end: 0, items: [item])
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.displayDay).font(.caption).foregroundStyle(.secondary)
                        ScheduleRow(item: item)
                    }
                }.buttonStyle(.plain)
            }
        }.listStyle(.plain)
    }

    private func moveWeek(_ delta: Int) { week = min(maximumWeek, max(1, week + delta)); hasCustomWeek = true }
    private func syncWeek() { if !hasCustomWeek { week = min(maximumWeek, max(1, currentWeek ?? 1)) } }
    private func date(for day: Int) -> Date? {
        guard let start = ScheduleWeek.parseStartDate(store.termSettings.startDates[store.selectedTerm] ?? "") else { return nil }
        return ScheduleWeek.date(startDate: start, week: week, day: day)
    }
    private func isToday(_ date: Date) -> Bool { ScheduleWeek.calendar.isDate(date, inSameDayAs: store.businessDate) }
    private func dateText(_ date: Date) -> String {
        let parts = ScheduleWeek.calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
}

private struct ScheduleOffsetKey: PreferenceKey {
    static let defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

struct ScheduleDetails: View {
    @Environment(\.dismiss) private var dismiss
    let items: [ScheduleItem]

    var body: some View {
        NavigationStack {
            List(items) { item in
                Section(item.course.isEmpty ? "未命名课程" : item.course) {
                    LabeledContent("星期", value: item.displayDay)
                    LabeledContent("节次", value: item.displaySections)
                    LabeledContent("地点", value: item.location.isEmpty ? "待定" : item.location)
                    if !item.teacher.isEmpty { LabeledContent("教师", value: item.teacher) }
                    if !item.weeks.isEmpty { LabeledContent("周次", value: item.weeks) }
                    if !item.note.isEmpty { Text(item.note) }
                }
            }
            .navigationTitle(items.count > 1 ? "同时间课程" : "课程详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct ScheduleScrollTracking: ViewModifier {
    @Binding var offset: CGPoint
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGPoint.self) { geometry in
                CGPoint(x: -geometry.contentOffset.x, y: -geometry.contentOffset.y)
            } action: { _, value in offset = value }
        } else {
            content
        }
    }
}
