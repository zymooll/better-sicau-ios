import SwiftUI

struct GradesView: View {
    @ObservedObject var store: AppStore
    @State private var searchText = ""
    @State private var termFilter = "全部"

    private var terms: [String] {
        ["全部"] + store.grades.map(\.term).filter { !$0.isEmpty }.reduce(into: [String]()) { result, term in
            if !result.contains(term) { result.append(term) }
        }.sorted(by: Self.termSort)
    }

    private var filteredGrades: [GradeItem] {
        store.grades.filter { grade in
            let matchesTerm = termFilter == "全部" || grade.term == termFilter
            let matchesSearch = searchText.isEmpty || [grade.displayCourse, grade.teacher, grade.courseType]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
            return matchesTerm && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !store.state(for: .grades).hasLoaded && store.grades.isEmpty {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredGrades.isEmpty && store.rankings.initialRequired == nil && store.rankings.all == nil {
                    EmptyStateView(
                        title: searchText.isEmpty ? "暂无成绩" : "没有匹配的成绩",
                        systemImage: searchText.isEmpty ? "chart.bar" : "magnifyingglass"
                    )
                } else {
                    List {
                        rankingsSection
                        Section {
                            if filteredGrades.isEmpty {
                                Text("当前筛选条件下暂无成绩")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredGrades) { grade in
                                    GradeRow(grade: grade)
                                }
                            }
                        } header: {
                            Text("成绩明细")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await store.loadGrades(forceRefresh: true) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("筛选：\(termFilter)").font(.subheadline)
                        Spacer()
                        if termFilter != "全部" { Button("清除筛选") { termFilter = "全部" } }
                    }.padding(.horizontal).padding(.vertical, 8)
                    QueryStatusView(store: store, scope: .grades) { Task { await store.loadGrades(forceRefresh: true) } }
                }
            }
            .navigationTitle("成绩")
            .searchable(text: $searchText, prompt: "课程或教师")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    termMenu
                    RefreshToolbarButton(isLoading: store.isLoading(.grades)) {
                        Task { await store.loadGrades(forceRefresh: true) }
                    }
                }
            }
            .task {
                if store.grades.isEmpty { await store.loadGrades(forceRefresh: false) }
            }
        }
    }

    @ViewBuilder
    private var rankingsSection: some View {
        if let initial = store.rankings.initialRequired {
            Section(initial.title.isEmpty ? "必修课排名" : initial.title) {
                RankingSummary(ranking: initial)
            }
        }
        if let all = store.rankings.all {
            Section(all.title.isEmpty ? "综合排名" : all.title) {
                RankingSummary(ranking: all)
            }
        }
    }

    private var termMenu: some View {
        Menu {
            ForEach(terms, id: \.self) { term in
                Button {
                    termFilter = term
                } label: {
                    if term == termFilter {
                        Label(term, systemImage: "checkmark")
                    } else {
                        Text(term)
                    }
                }
            }
        } label: {
            Label(termFilter, systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
    }

    nonisolated private static func termSort(_ lhs: String, _ rhs: String) -> Bool {
        lhs.replacingOccurrences(of: "-", with: "") > rhs.replacingOccurrences(of: "-", with: "")
    }
}

struct RankingSummary: View {
    let ranking: GradeRanking

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("排名按教务系统整体统计，不随本页学期筛选变化")
                .font(.caption).foregroundStyle(.secondary)
            if !ranking.summary.isEmpty {
                Text(ranking.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ranking.metrics.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 14) {
                    ForEach(ranking.metrics) { metric in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.value)
                                .font(.headline.weight(.semibold))
                                .monospacedDigit()
                            Text(metric.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            if ranking.metrics.isEmpty && !ranking.rawText.isEmpty {
                Text(ranking.rawText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }
}

struct GradeRow: View {
    let grade: GradeItem

    private var scoreColor: Color {
        guard let value = Double(grade.score) else { return .primary }
        if value >= 90 { return .sicauGreen }
        if value >= 60 { return .primary }
        return .red
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(grade.displayCourse)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if !grade.teacher.isEmpty { Text(grade.teacher) }
                    if !grade.credit.isEmpty { Text("学分 \(grade.credit)") }
                    if !grade.term.isEmpty { Text(grade.term) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(grade.displayScore)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor)
                if !grade.gradePoint.isEmpty {
                    Text(grade.gradePoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
