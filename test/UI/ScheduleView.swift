import SwiftUI

struct ScheduleView: View {
    @ObservedObject var store: AppStore
    @State private var searchText = ""
    @State private var mode: DisplayMode = .overview

    enum DisplayMode: String, CaseIterable, Identifiable {
        case overview
        case list

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "总览"
            case .list: return "列表"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TermSelector(store: store)
                QueryStatusView(store: store, scope: .schedule) { Task { await store.loadSchedule(forceRefresh: true) } }
                Picker("显示方式", selection: $mode) {
                    ForEach(DisplayMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(Color(uiColor: .systemGroupedBackground))

                Group {
                    switch mode {
                    case .overview:
                        overviewContent
                    case .list:
                        ScheduleListView(store: store, searchText: searchText)
                    }
                }
            }
            .navigationTitle("课表")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "课程、教师或教室")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: store.isLoading(.schedule)) {
                        Task { await store.loadSchedule(forceRefresh: true) }
                    }
                }
            }
            .task(id: store.selectedTerm) {
                if store.termSettings.currentTerm.isEmpty { await store.loadTermSettings() }
                await store.loadSchedule(forceRefresh: false)
            }
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        if !store.state(for: .schedule).hasLoaded && store.schedule.isEmpty {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.schedule.isEmpty {
            EmptyStateView(title: "暂无课表", systemImage: "calendar")
        } else {
            ScheduleOverviewView(store: store, searchText: searchText)
        }
    }


}

private struct ScheduleListView: View {
    @ObservedObject var store: AppStore
    let searchText: String
    @State private var didScrollToToday = false

    private var filteredSchedule: [ScheduleItem] {
        guard !searchText.isEmpty else { return store.schedule }
        return store.schedule.filter {
            [$0.course, $0.teacher, $0.location, $0.weeks]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedSchedule: [(day: String, items: [ScheduleItem])] {
        let grouped = Dictionary(grouping: filteredSchedule, by: \.displayDay)
        return grouped.map { day, items in
            (day, items.sorted { ($0.sectionStart ?? .max) < ($1.sectionStart ?? .max) })
        }
        .sorted { lhs, rhs in
            let left = lhs.items.first?.dayOfWeek ?? .max
            let right = rhs.items.first?.dayOfWeek ?? .max
            return left == right ? lhs.day < rhs.day : left < right
        }
    }

    var body: some View {
        Group {
            if !store.state(for: .schedule).hasLoaded && store.schedule.isEmpty {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groupedSchedule.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty ? "暂无课表" : "没有匹配的课程",
                    systemImage: searchText.isEmpty ? "calendar" : "magnifyingglass"
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(groupedSchedule.enumerated()), id: \.offset) { entry in
                            Section(entry.element.day) {
                                ForEach(entry.element.items) { item in
                                    ScheduleRow(
                                        item: item,
                                        isToday: store.isScheduleItemToday(item),
                                        isMuted: store.isTodayInSelectedTerm && (store.currentTeachingWeek.map { !item.isActive(inWeek: $0) } ?? false)
                                    )
                                }
                            }
                            .id(sectionID(for: entry.element))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await store.loadSchedule(forceRefresh: true) }
                    .onAppear { scrollToToday(proxy) }
                    .onChange(of: store.selectedTerm) { _, _ in
                        didScrollToToday = false
                    }
                    .onChange(of: store.schedule.count) { _, count in
                        if count > 0 { scrollToToday(proxy) }
                    }
                }
            }
        }
    }

    private func sectionID(for group: (day: String, items: [ScheduleItem])) -> String {
        "schedule-day-\(group.items.first?.dayOfWeek ?? 0)"
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        guard !didScrollToToday else { return }
        didScrollToToday = true
        let id = "schedule-day-\(store.todayWeekday)"
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .top)
        }
    }
}

struct ScheduleRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: ScheduleItem
    var isToday = false
    var isMuted = false

    private var tint: Color { Color.scheduleTint(forDay: item.dayOfWeek) }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.course.isEmpty ? "未命名课程" : item.course).font(.headline)
                Text(item.displaySections).font(.subheadline).foregroundStyle(tint)
                if isToday && !isMuted { Text("今天").font(.caption).foregroundStyle(tint) }
                if !item.location.isEmpty { Text(item.location).foregroundStyle(.secondary) }
                if !item.teacher.isEmpty { Text(item.teacher).foregroundStyle(.secondary) }
                if !item.weeks.isEmpty { Text(item.weeks).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        } else {
            normalRow
        }
    }

    private var normalRow: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 4, height: 54)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.course.isEmpty ? "未命名课程" : item.course)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if isToday && !isMuted {
                        Text("今天")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint))
                    }
                    Spacer(minLength: 8)
                    Text(item.displaySections)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.trailing)
                }

                if !item.location.isEmpty {
                    Label(item.location, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    if !item.teacher.isEmpty {
                        Label(item.teacher, systemImage: "person")
                    }
                    if !item.weeks.isEmpty {
                        Label(item.weeks, systemImage: "repeat")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .opacity(isMuted ? 0.70 : 1)
        .listRowBackground(isToday && !isMuted ? tint.opacity(0.06) : nil)
        .accessibilityElement(children: .combine)
    }
}

struct CompactScheduleRow: View {
    let item: ScheduleItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.course.isEmpty ? "未命名课程" : item.course)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text([item.location, item.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.displaySections)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.sicauGreen)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
