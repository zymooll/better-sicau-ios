import SwiftUI

/// In-app log viewer: reads the in-memory ring buffer, filters by level and
/// category, and exports either the redacted or the full (sensitive) text.
struct LogViewerScreen: View {
    @State private var entries: [LogEntry] = []
    @State private var selectedLevels: Set<LogLevel> = []
    @State private var selectedCategory: LogCategory?
    @State private var searchText = ""
    @State private var exportPayload: LogExportPayload?
    @State private var confirmClear = false

    private let displayLimit = 500

    var body: some View {
        List {
            if filteredEntries.isEmpty {
                ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass", description: Text("完成一次操作后日志会出现在这里"))
            } else {
                ForEach(Array(filteredEntries.prefix(displayLimit))) { entry in
                    LogRow(entry: entry)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("日志")
        .searchable(text: $searchText, prompt: "搜索日志内容")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                levelFilterMenu
                categoryFilterMenu

                Menu {
                    Button {
                        Task { await prepareExport(includeSensitive: false) }
                    } label: {
                        Label("导出（脱敏）", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Task { await prepareExport(includeSensitive: true) }
                    } label: {
                        Label("导出（完整，含敏感）", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("清空所有日志？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    await Log.store.clear()
                    await reload()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $exportPayload) { payload in
            LogExportSheet(text: payload.text)
        }
    }

    private var filteredEntries: [LogEntry] {
        entries.filter { entry in
            let levelMatches = selectedLevels.isEmpty || selectedLevels.contains(entry.level)
            let categoryMatches = selectedCategory.map { entry.category == $0 } ?? true
            let searchMatches = searchText.isEmpty
                || entry.redactedText.localizedCaseInsensitiveContains(searchText)
                || entry.category.rawValue.localizedCaseInsensitiveContains(searchText)
            return levelMatches && categoryMatches && searchMatches
        }
    }

    private func reload() async {
        entries = await Log.store.snapshot()
    }

    private func prepareExport(includeSensitive: Bool) async {
        let text = await Log.store.export(includeSensitive: includeSensitive)
        exportPayload = LogExportPayload(text: text)
    }

    private var levelFilterMenu: some View {
        Menu {
            ForEach(LogLevel.allCases, id: \.self) { level in
                Button {
                    if selectedLevels.contains(level) {
                        selectedLevels.remove(level)
                    } else {
                        selectedLevels.insert(level)
                    }
                } label: {
                    if selectedLevels.isEmpty || selectedLevels.contains(level) {
                        Label(level.title, systemImage: "checkmark")
                    } else {
                        Text(level.title)
                    }
                }
            }
            if !selectedLevels.isEmpty {
                Divider()
                Button("全部级别") { selectedLevels = [] }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private var categoryFilterMenu: some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                if selectedCategory == nil {
                    Label("全部类别", systemImage: "checkmark")
                } else {
                    Text("全部类别")
                }
            }
            Divider()
            ForEach(LogCategory.allCases, id: \.self) { category in
                Button {
                    selectedCategory = category
                } label: {
                    if selectedCategory == category {
                        Label(category.rawValue, systemImage: "checkmark")
                    } else {
                        Text(category.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .orange
        case .error: return .red
        case .fault: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 8, height: 8)
                Text(entry.level.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(levelColor)
                Text(entry.category.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Spacer()
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.redactedText)
                .font(.caption)
                .textSelection(.enabled)
            Text(entry.source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct LogExportPayload: Identifiable {
    let id = UUID()
    let text: String
}

private struct LogExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("导出日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text)
                }
            }
        }
    }
}
