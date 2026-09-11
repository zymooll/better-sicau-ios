import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var confirmLogout = false
    @State private var confirmCredentialClear = false
    @State private var startDateInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    LabeledContent("账号", value: store.currentUser?.username ?? "-")
                    if let userType = store.currentUser?.userType, !userType.isEmpty {
                        LabeledContent("类型", value: userType)
                    }
                    if let date = store.currentUser?.loggedInAt {
                        LabeledContent("本次登录") {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("学期") {
                    Picker("当前学期", selection: Binding(get: { store.selectedTerm }, set: { term in
                        Task { await store.changeTerm(to: term) }
                    })) {
                        ForEach(store.availableTerms, id: \.self) { term in
                            Text(term).tag(term)
                        }
                    }

                    startDateEditor
                }

                Section("本机数据") {
                    LabeledContent("查询缓存", value: "5 分钟")
                    Button("清除保存的账号信息", role: .destructive) {
                        confirmCredentialClear = true
                    }
                    .disabled(store.isLoading(.logout))
                }

                Section("诊断") {
                    NavigationLink {
                        LogViewerScreen()
                    } label: {
                        Label("日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section {
                    Button("退出登录", role: .destructive) {
                        confirmLogout = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(store.isLoading(.logout))
                }

                Section("关于") {
                    LabeledContent("Better Sicau", value: versionText)
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("退出当前账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Task { await store.logout() }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("清除保存的账号信息？", isPresented: $confirmCredentialClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    Task { await store.clearSavedCredentials() }
                }
                Button("取消", role: .cancel) {}
            }
            .task {
                if store.termSettings.currentTerm.isEmpty { await store.loadTermSettings() }
            }
        }
    }

    /// The selected term's start date: presets fill in automatically,
    /// missing values prompt the user to enter one. Weekly-number and exam
    /// window calculations degrade gracefully without it, but filling it in
    /// restores full accuracy.
    @ViewBuilder
    private var startDateEditor: some View {
        let currentValue = store.termSettings.startDates[store.selectedTerm] ?? ""
        let hasValue = !currentValue.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if hasValue {
                LabeledContent("第一周参考日期", value: currentValue)
            } else {
                Label("未设置教学日期，暂不能判断今日课程", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.sicauOrange)
            }

            Text("以此日期当天或之后的第一个周一作为第一教学周。")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(hasValue ? "修改开学日期" : "填写开学日期，如 2026-03-01", text: $startDateInput)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("保存") {
                    Task { await store.setTermStartDate(startDateInput, for: store.selectedTerm) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.sicauButtonGreen)
                .disabled(store.selectedTerm.isEmpty)
            }
        }
        .onAppear { syncStartDateInput() }
        .onChange(of: store.selectedTerm) { _, _ in syncStartDateInput() }
        .onChange(of: store.termSettings.startDates) { _, _ in syncStartDateInput() }
    }

    private func syncStartDateInput() {
        startDateInput = store.termSettings.startDates[store.selectedTerm] ?? ""
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
