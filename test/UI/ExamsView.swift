import SwiftUI

struct ExamsView: View {
    @ObservedObject var store: AppStore
    @State private var filter: ExamFilter = .all
    @State private var allTerms = true
    @State private var searchText = ""

    enum ExamFilter: String, CaseIterable, Identifiable {
        case regular
        case resit
        case all

        var id: String { rawValue }
        var title: String {
            switch self {
            case .regular: return "正考"
            case .resit: return "缓补考"
            case .all: return "全部"
            }
        }
    }

    private var filteredExams: [ExamItem] {
        (allTerms ? store.visibleExams : store.examsForSelectedTerm).filter { exam in
            let matchesType: Bool
            switch filter {
            case .regular: matchesType = !exam.isResit
            case .resit: matchesType = exam.isResit
            case .all: matchesType = true
            }
            let matchesSearch = searchText.isEmpty || [exam.course, exam.location, exam.teacher, exam.time]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesSearch
        }
    }

    private var groupedExams: [(term: String, exams: [ExamItem])] {
        Dictionary(grouping: filteredExams) { exam in
            guard let term = store.assignedTerm(for: exam) else { return "学期待确认" }
            return exam.term.isEmpty ? "\(term)（按日期推测）" : term
        }
            .map { ($0.key, ExamItem.sortedByDate($0.value)) }
            .sorted { $0.term > $1.term }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Toggle("全部学期", isOn: $allTerms).padding(.horizontal).padding(.top, 8)
                if !allTerms { TermSelector(store: store) }
                QueryStatusView(store: store, scope: .exams) { Task { await store.loadExams(forceRefresh: true) } }
                Picker("考试类型", selection: $filter) {
                    ForEach(ExamFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemGroupedBackground))

                Group {
                    if !store.state(for: .exams).hasLoaded && store.exams.isEmpty {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if groupedExams.isEmpty {
                        EmptyStateView(
                            title: searchText.isEmpty ? "暂无\(filter.title)安排" : "没有匹配的考试",
                            systemImage: searchText.isEmpty ? "calendar.badge.checkmark" : "magnifyingglass"
                        )
                    } else {
                        List {
                            ForEach(Array(groupedExams.enumerated()), id: \.offset) { entry in
                                Section(entry.element.term) {
                                    ForEach(entry.element.exams) { exam in
                                        ExamRow(exam: exam)
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .refreshable { await store.loadExams(forceRefresh: true) }
                    }
                }
            }
            .navigationTitle("考试")
            .searchable(text: $searchText, prompt: "课程、教师或考场")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: store.isLoading(.exams)) {
                        Task { await store.loadExams(forceRefresh: true) }
                    }
                }
            }
            .task {
                if store.exams.isEmpty { await store.loadExams(forceRefresh: false) }
            }
        }
    }
}

struct ExamRow: View {
    let exam: ExamItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(exam.course.isEmpty ? "未命名课程" : exam.course)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !exam.type.isEmpty {
                    Text(exam.type)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(exam.isResit ? Color.sicauOrange : Color.sicauGreen)
                }
            }

            if !exam.time.isEmpty {
                Label(exam.time, systemImage: "clock")
                    .font(.subheadline)
            }

            HStack(spacing: 12) {
                if !exam.location.isEmpty {
                    Label(exam.location, systemImage: "mappin.and.ellipse")
                }
                if !exam.seat.isEmpty {
                    Label("座位 \(exam.seat)", systemImage: "chair")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            if !exam.note.isEmpty {
                Text(exam.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct CompactExamRow: View {
    let exam: ExamItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(exam.course.isEmpty ? "未命名课程" : exam.course)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text([exam.time, exam.location].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if exam.isResit {
                Text("缓补考")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.sicauOrange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
