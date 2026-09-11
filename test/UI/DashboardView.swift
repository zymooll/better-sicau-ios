import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedTab: MainTabView.AppTab

    private var todaysSchedule: [ScheduleItem] {
        return store.schedule
            .filter { store.isScheduleItemToday($0) }
            .sorted { ($0.sectionStart ?? .max) < ($1.sectionStart ?? .max) }
    }

    private var upcomingExams: [ExamItem] {
        Array(ExamItem.sortedByDate(store.visibleExams.filter {
            guard let date = $0.parsedDate else { return true }
            return date >= ScheduleWeek.calendar.startOfDay(for: store.businessDate)
        }).prefix(3))
    }

    var body: some View {
        NavigationStack {
            List {
                Section { TermSelector(store: store) }
                summarySection
                todaySection
                examSection
                Section("成绩更新") {
                    QueryStatusView(store: store, scope: .grades) { Task { await store.loadGrades(forceRefresh: true) } }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Better Sicau")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(
                        isLoading: store.isLoading(.grades) || store.isLoading(.exams) || store.isLoading(.schedule)
                    ) {
                        Task { await store.refreshAll() }
                    }
                }
            }
            .refreshable { await store.refreshAll() }
        }
    }

    private var summarySection: some View {
        Section("概览") {
            HStack(spacing: 18) {
                StatPill(value: store.state(for: .schedule).hasLoaded ? "\(store.schedule.count)" : "—", label: "课表安排", tint: .sicauGreen)
                Divider().frame(height: 38)
                StatPill(value: store.state(for: .exams).hasLoaded ? "\(store.exams.count)" : "—", label: "全部考试", tint: .sicauOrange)
                Divider().frame(height: 38)
                StatPill(value: store.state(for: .grades).hasLoaded ? "\(store.grades.count)" : "—", label: "全部成绩", tint: .sicauBlue)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var todaySection: some View {
        Section {
            QueryStatusView(store: store, scope: .schedule) { Task { await store.loadSchedule(forceRefresh: true) } }
            if let message = store.todayScheduleMessage {
                Label(message, systemImage: "calendar.badge.exclamationmark").foregroundStyle(.secondary)
            } else if !store.state(for: .schedule).hasLoaded {
                EmptyView()
            } else if todaysSchedule.isEmpty {
                Label("今天没有课程", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(todaysSchedule.prefix(3)) { item in
                    CompactScheduleRow(item: item)
                }
            }
        } header: {
            Button("今日课表") { selectedTab = .schedule }
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var examSection: some View {
        Section {
            QueryStatusView(store: store, scope: .exams) { Task { await store.loadExams(forceRefresh: true) } }
            if !store.state(for: .exams).hasLoaded {
                EmptyView()
            } else if upcomingExams.isEmpty {
                Label("暂无待考安排", systemImage: "calendar.badge.checkmark")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(upcomingExams) { exam in
                    CompactExamRow(exam: exam)
                }
            }
        } header: {
            Button("近期考试 · 全部学期") { selectedTab = .exams }
                .foregroundStyle(.primary)
        }
    }

}
