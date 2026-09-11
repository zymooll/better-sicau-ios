import Combine
import Foundation
import SwiftUI

enum LoginMode: String, CaseIterable, Identifiable, Sendable {
    case password
    case wechat
    case sms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "账号登录"
        case .wechat: return "微信登录"
        case .sms: return "短信登录"
        }
    }
}

enum AppSessionState: Equatable, Sendable {
    case restoring
    case signedOut
    case signedIn(UserProfile)
}

enum LoadingScope: Hashable, Sendable {
    case bootstrap
    case captcha
    case recognition
    case login
    case sms
    case wechat
    case grades
    case exams
    case schedule
    case logout
}

struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String = "提示", message: String) {
        self.title = title
        self.message = message
    }
}

@MainActor
final class AppStore: ObservableObject {
    let authService: any AuthService
    let academicService: any AcademicService

    @Published var sessionState: AppSessionState = .restoring
    @Published var loginMode: LoginMode = .password {
        didSet {
            guard loginMode != oldValue else { return }
            stopWechatLogin()
            wechatState = nil
        }
    }
    @Published var username = ""
    @Published var password = ""
    @Published var captchaText = "" { didSet { captchaInputVersion += 1 } }
    @Published var phone = ""
    @Published var smsCode = ""
    @Published var rememberPassword = false
    @Published private(set) var captchaChallenge: CaptchaChallenge?
    @Published private(set) var captchaRecognition: CaptchaRecognition?
    @Published private(set) var wechatState: WechatLoginState?
    @Published var notice: AppNotice?
    @Published private(set) var loadingScopes: Set<LoadingScope> = []
    @Published private(set) var grades: [GradeItem] = []
    @Published private(set) var rankings = GradeRankings()
    @Published private(set) var exams: [ExamItem] = []
    @Published private(set) var schedule: [ScheduleItem] = []
    @Published private(set) var termSettings = TermSettings(currentTerm: "", startDates: [:])
    @Published var selectedTerm = ""
    @Published private(set) var didBootstrap = false
    @Published private(set) var bootstrapMessage = "读取本机账号信息"
    @Published private(set) var smsCooldown = 0

    @Published private(set) var academicStates: [LoadingScope: AcademicLoadState] = [:]
    @Published private(set) var businessDate = Date()
    private var academicTasks: [LoadingScope: Task<Void, Never>] = [:]
    private var requestIDs: [LoadingScope: UUID] = [:]
    private var sessionGeneration = UUID()
    private var captchaInputVersion = 0
    private var smsDeadline: Date?
    private var wechatRequestID = UUID()
    private var wechatPollingTask: Task<Void, Never>?
    private var smsCooldownTask: Task<Void, Never>?
    private var appIsActive = true
    private let defaults: UserDefaults
    private let now: () -> Date
    private let selectedTermKey = "better-sicau.selected-term"

    init(
        authService: any AuthService,
        academicService: any AcademicService,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { .now }
    ) {
        self.authService = authService
        self.academicService = academicService
        self.defaults = defaults
        self.now = now
        self.selectedTerm = defaults.string(forKey: selectedTermKey) ?? ""
        self.businessDate = now()
    }

    deinit {
        wechatPollingTask?.cancel()
        smsCooldownTask?.cancel()
        academicTasks.values.forEach { $0.cancel() }
    }

    var currentUser: UserProfile? {
        guard case .signedIn(let profile) = sessionState else { return nil }
        return profile
    }

    var isAuthenticated: Bool {
        if case .signedIn = sessionState { return true }
        return false
    }

    var availableTerms: [String] {
        // The picker always offers the generated range (through 2035-2036-2)
        // plus any term labels that actually appear in data or settings.
        var values = Set(AcademicTerm.availableTerms())
        values.formUnion(termSettings.startDates.keys)
        if !termSettings.currentTerm.isEmpty { values.insert(termSettings.currentTerm) }
        grades.map(\.term).filter { !$0.isEmpty }.forEach { values.insert($0) }
        exams.map(\.term).filter { !$0.isEmpty }.forEach { values.insert($0) }
        schedule.map(\.term).filter { !$0.isEmpty }.forEach { values.insert($0) }
        return values.sorted(by: Self.termSort)
    }

    /// The current 1-based teaching week for the selected term, if its
    /// start date is known and has already passed.
    var currentTeachingWeek: Int? {
        let startDate = termSettings.startDates[selectedTerm] ?? ""
        return ScheduleWeek.currentWeek(startDateText: startDate, now: businessDate)
    }

    /// Today as a Monday-based weekday number (1...7).
    var todayWeekday: Int {
        let calendarWeekday = ScheduleWeek.calendar.component(.weekday, from: businessDate)
        return (calendarWeekday + 5) % 7 + 1
    }

    /// Whether today's date falls within the selected term's start date and
    /// the following term's start date (or a 26-week fallback window).
    var isTodayInSelectedTerm: Bool {
        guard let termStart = ScheduleWeek.parseStartDate(termSettings.startDates[selectedTerm] ?? "") else { return false }
        let calendar = ScheduleWeek.calendar
        let today = calendar.startOfDay(for: businessDate)
        let start = calendar.startOfDay(for: termStart)
        guard today >= start else { return false }

        let laterStarts = termSettings.startDates.values
            .compactMap(ScheduleWeek.parseStartDate)
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 > start }
        if let nextStart = laterStarts.min() {
            return today < nextStart
        }

        guard let fallbackEnd = calendar.date(byAdding: .weekOfYear, value: 26, to: start) else { return false }
        return today < fallbackEnd
    }

    /// Whether a schedule item actually occurs today: same weekday, the
    /// selected term contains today, and the item is active this teaching week.
    func isScheduleItemToday(_ item: ScheduleItem) -> Bool {
        guard item.dayOfWeek == todayWeekday else { return false }
        guard isTodayInSelectedTerm, let week = currentTeachingWeek else { return false }
        return item.isActive(inWeek: week)
    }

    /// Preserve source labels and never delete records based on inferred dates.
    var visibleExams: [ExamItem] { exams }

    func assignedTerm(for exam: ExamItem) -> String? {
        let source = exam.term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty { return source }
        guard let date = exam.parsedDate else { return nil }
        let matching = termWindows().filter { $0.window.contains(date) }
        // Overlapping windows are ambiguous; keep them in the unknown group.
        return matching.count == 1 ? matching[0].term : nil
    }

    var examsForSelectedTerm: [ExamItem] {
        guard !selectedTerm.isEmpty else { return exams }
        return exams.filter { assignedTerm(for: $0).map { $0 == selectedTerm } ?? true }
    }

    var todayScheduleMessage: String? {
        if termSettings.startDates[selectedTerm] == nil { return "请设置第一教学周日期，以确认今日课程" }
        if !isTodayInSelectedTerm { return "当前查看的学期不包含今天" }
        return nil
    }

    func state(for scope: LoadingScope) -> AcademicLoadState {
        academicStates[scope] ?? AcademicLoadState()
    }

    func updateBusinessDate() {
        businessDate = now()
        updateSMSCooldown()
    }

    func watchBusinessDate() async {
        while !Task.isCancelled {
            updateBusinessDate()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    var isBusy: Bool { !loadingScopes.isEmpty }

    func isLoading(_ scope: LoadingScope) -> Bool {
        loadingScopes.contains(scope)
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        begin(.bootstrap)
        defer { end(.bootstrap) }

        let saved = await authService.savedCredentials()
        if let saved {
            username = saved.username
            password = saved.password
            rememberPassword = true
        }

        bootstrapMessage = "验证已保存的登录状态"
        if let profile = await authService.restoreSession() {
            sessionState = .signedIn(profile)
            Log.info(.session, LogMessage("启动恢复会话成功：{username}", sensitive: ["username": profile.username]))
            await loadTermSettings()
            await loadInitialAcademicData()
        } else {
            sessionState = .signedOut
            Log.info(.session, LogMessage("启动未登录，显示登录页"))
            await refreshCaptcha()
        }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active {
            updateBusinessDate()
            resumeWechatPollingIfNeeded()
        } else {
            wechatPollingTask?.cancel()
            wechatPollingTask = nil
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func refreshCaptcha() async {
        guard !isLoading(.captcha), !isLoading(.recognition) else { return }
        let expected = sessionGeneration
        begin(.captcha)
        do {
            let challenge = try await authService.fetchCaptcha()
            guard sessionGeneration == expected else { return }
            captchaChallenge = challenge
            captchaRecognition = nil
            captchaText = ""
        } catch {
            guard sessionGeneration == expected else { return }
            end(.captcha)
            if isCancellation(error) { return }
            await handle(error)
            return
        }
        end(.captcha)
        await performCaptchaRecognition(reportFailure: false)
    }

    func recognizeCaptcha() async {
        await performCaptchaRecognition(reportFailure: true)
    }

    private func performCaptchaRecognition(reportFailure: Bool) async {
        guard let challenge = captchaChallenge, !isLoading(.recognition) else { return }
        let challengeID = challenge.uuid
        let inputVersion = captchaInputVersion
        let expected = sessionGeneration
        begin(.recognition)
        defer { if sessionGeneration == expected { end(.recognition) } }
        do {
            let result = try await authService.recognizeCaptcha(challenge)
            guard sessionGeneration == expected, captchaChallenge?.uuid == challengeID else { return }
            let normalized = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let validCharacters = normalized.range(of: "^[0-9]{4}$", options: .regularExpression) != nil
            guard validCharacters, result.confidence >= 0.55 else {
                captchaRecognition = result
                if reportFailure {
                    await handle(AppError.invalidCaptcha("未能可靠识别验证码，请手动输入"))
                }
                return
            }
            captchaRecognition = CaptchaRecognition(text: normalized, confidence: result.confidence)
            if captchaInputVersion == inputVersion { captchaText = normalized }
        } catch {
            if isCancellation(error) { return }
            guard sessionGeneration == expected, captchaChallenge?.uuid == challengeID else { return }
            captchaRecognition = CaptchaRecognition(text: "", confidence: 0)
            if reportFailure { await handle(error) }
        }
    }

    func loginWithPassword() async {
        guard !isLoading(.login), !isAuthenticated else { return }
        stopWechatLogin()
        wechatState = nil
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = captchaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { notice = AppNotice(message: "请输入学号或账号"); return }
        guard !password.isEmpty else { notice = AppNotice(message: "请输入密码"); return }
        guard let challenge = captchaChallenge else { notice = AppNotice(message: "请先获取验证码"); return }
        guard !code.isEmpty else { notice = AppNotice(message: "请输入验证码"); return }

        let expectedSession = sessionGeneration
        begin(.login)
        defer { end(.login) }
        do {
            let profile = try await authService.login(
                username: account,
                password: password,
                captcha: code,
                challenge: challenge,
                rememberPassword: rememberPassword
            )
            guard sessionGeneration == expectedSession else { return }
            if !rememberPassword { password = "" }
            username = account
            sessionState = .signedIn(profile)
            Log.notice(.session, LogMessage("密码登录完成，进入主界面：{username}", sensitive: ["username": account]))
            await loadTermSettings()
            await loadInitialAcademicData()
        } catch {
            guard sessionGeneration == expectedSession, !isCancellation(error) else { return }
            Log.error(.auth, LogMessage("密码登录失败：\(error.localizedDescription)"))
            await handle(error)
            await refreshCaptcha()
        }
    }

    func sendSMSCode() async {
        guard !isLoading(.sms) else { return }
        updateSMSCooldown()
        let number = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = captchaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.range(of: "^1[3-9]\\d{9}$", options: .regularExpression) != nil else {
            notice = AppNotice(message: "请输入有效的手机号")
            return
        }
        guard let challenge = captchaChallenge else { notice = AppNotice(message: "请先获取验证码"); return }
        guard !code.isEmpty else { notice = AppNotice(message: "请输入验证码"); return }
        guard smsCooldown == 0 else { return }

        let expected = sessionGeneration
        begin(.sms)
        defer { end(.sms) }
        do {
            try await authService.sendSMSCode(phone: number, captcha: code, challenge: challenge)
            guard sessionGeneration == expected else { return }
            startSMSCooldown()
            notice = AppNotice(title: "验证码已发送", message: "短信验证码已发送，请在有效期内完成登录")
        } catch {
            guard sessionGeneration == expected, !isCancellation(error) else { return }
            await handle(error)
            await refreshCaptcha()
        }
    }

    func loginWithSMS() async {
        guard !isLoading(.login), !isAuthenticated else { return }
        stopWechatLogin()
        wechatState = nil
        let number = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = smsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.range(of: "^1[3-9]\\d{9}$", options: .regularExpression) != nil else {
            notice = AppNotice(message: "请输入有效的手机号")
            return
        }
        guard !code.isEmpty else { notice = AppNotice(message: "请输入短信验证码"); return }

        let expectedSession = sessionGeneration
        begin(.login)
        defer { end(.login) }
        do {
            let profile = try await authService.loginWithSMS(phone: number, code: code)
            guard sessionGeneration == expectedSession else { return }
            smsCode = ""
            sessionState = .signedIn(profile)
            Log.notice(.session, LogMessage("短信登录完成，进入主界面：{phone}", sensitive: ["phone": number]))
            await loadTermSettings()
            await loadInitialAcademicData()
        } catch {
            guard sessionGeneration == expectedSession, !isCancellation(error) else { return }
            Log.error(.auth, LogMessage("短信登录失败：\(error.localizedDescription)"))
            await handle(error)
        }
    }

    func startWechatLogin() async {
        guard !isLoading(.wechat), !isAuthenticated, loginMode == .wechat else { return }
        stopWechatLogin()
        let requestID = wechatRequestID
        begin(.wechat)
        defer { end(.wechat) }
        do {
            let state = try await authService.startWechatLogin()
            guard requestID == wechatRequestID, loginMode == .wechat, !isAuthenticated else { return }
            wechatState = state
            resumeWechatPollingIfNeeded()
        } catch {
            guard requestID == wechatRequestID, !isCancellation(error) else { return }
            await handle(error)
        }
    }

    func restartWechatLogin() async {
        wechatState = nil
        await startWechatLogin()
    }

    func stopWechatLogin() {
        wechatRequestID = UUID()
        wechatPollingTask?.cancel()
        wechatPollingTask = nil
    }

    private func resetSessionData() {
        sessionGeneration = UUID()
        academicTasks.values.forEach { $0.cancel() }
        academicTasks = [:]
        requestIDs = [:]
        academicStates = [:]
        loadingScopes.subtract([.grades, .exams, .schedule, .captcha, .recognition])
        stopWechatLogin()
        wechatState = nil
        smsCooldownTask?.cancel()
        smsCooldownTask = nil
        smsDeadline = nil
        smsCooldown = 0
        grades = []
        rankings = GradeRankings()
        exams = []
        schedule = []
        captchaChallenge = nil
        captchaRecognition = nil
        captchaText = ""
        password = ""
        phone = ""
        smsCode = ""
    }

    func logout() async {
        guard !isLoading(.logout) else { return }
        begin(.logout)
        defer { end(.logout) }
        resetSessionData()
        sessionState = .signedOut
        await authService.logout()
        await academicService.clearCache()
        Log.info(.session, LogMessage("用户主动退出登录"))
        await refreshCaptcha()
    }

    func clearSavedCredentials() async {
        do {
            try await authService.clearSavedCredentials()
            rememberPassword = false
            username = ""
            password = ""
            notice = AppNotice(message: "已清除保存的账号信息")
        } catch {
            if isCancellation(error) { return }
            await handle(error)
        }
    }

    func loadTermSettings() async {
        let settings = await academicService.termSettings()
        termSettings = settings
        if selectedTerm.isEmpty {
            selectedTerm = settings.currentTerm
        } else if !availableTerms.contains(selectedTerm), !settings.currentTerm.isEmpty {
            selectedTerm = settings.currentTerm
        }
        if !selectedTerm.isEmpty { defaults.set(selectedTerm, forKey: selectedTermKey) }
    }

    func selectTerm(_ term: String) {
        guard !term.isEmpty else { return }
        if selectedTerm != term {
            academicTasks[.schedule]?.cancel()
            academicTasks[.schedule] = nil
            requestIDs[.schedule] = nil
            end(.schedule)
            schedule = []
            academicStates[.schedule] = AcademicLoadState()
        }
        selectedTerm = term
        defaults.set(term, forKey: selectedTermKey)
        Log.debug(.ui, LogMessage("切换学期选择：\(term)"))
    }

    func loadInitialAcademicData(forceRefresh: Bool = false) async {
        guard isAuthenticated else { return }
        let expected = sessionGeneration
        if termSettings.currentTerm.isEmpty { await loadTermSettings() }
        // Prioritize the information used by the home screen.
        await loadSchedule(forceRefresh: forceRefresh)
        guard isAuthenticated, sessionGeneration == expected else { return }
        await loadExams(forceRefresh: forceRefresh)
        guard isAuthenticated, sessionGeneration == expected else { return }
        await loadGrades(forceRefresh: forceRefresh)
    }

    func refreshAll() async {
        await loadTermSettings()
        await loadInitialAcademicData(forceRefresh: true)
    }

    func loadGrades(forceRefresh: Bool = false) async {
        await runQuery(.grades) { store, progress in
            let snapshot = try await store.academicService.fetchGrades(forceRefresh: forceRefresh, progress: progress)
            try Task.checkCancellation()
            store.grades = Self.unique(snapshot.grades)
            store.rankings = snapshot.rankings
            store.academicStates[.grades, default: AcademicLoadState()].warnings = snapshot.warnings
        }
    }

    func loadExams(forceRefresh: Bool = false) async {
        await runQuery(.exams) { store, progress in
            let result = try await store.academicService.fetchExams(forceRefresh: forceRefresh, progress: progress)
            try Task.checkCancellation()
            store.exams = Self.unique(result)
        }
    }

    func loadSchedule(forceRefresh: Bool = false) async {
        let term = selectedTerm
        guard !term.isEmpty else { return }
        await runQuery(.schedule) { store, progress in
            let result = try await store.academicService.fetchSchedule(term: term, forceRefresh: forceRefresh, progress: progress)
            try Task.checkCancellation()
            guard store.selectedTerm == term else { throw CancellationError() }
            store.schedule = Self.unique(result)
        }
    }

    private static func unique<Item: Identifiable>(_ items: [Item]) -> [Item] where Item.ID: Hashable {
        var seen: Set<Item.ID> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    private func runQuery(
        _ scope: LoadingScope,
        operation: @escaping @MainActor (AppStore, AcademicProgress?) async throws -> Void
    ) async {
        if let existing = academicTasks[scope] {
            await existing.value
            return
        }
        let requestID = UUID()
        let expected = sessionGeneration
        requestIDs[scope] = requestID
        begin(scope)
        academicStates[scope, default: AcademicLoadState()].error = nil
        academicStates[scope, default: AcademicLoadState()].progress = .running(["准备查询"], at: 0)
        let progress: AcademicProgress = { [weak self] value in
            await self?.receiveProgress(value, scope: scope, requestID: requestID, generation: expected)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestIDs[scope] == requestID {
                    self.end(scope)
                    self.academicStates[scope, default: AcademicLoadState()].progress = nil
                    self.academicTasks[scope] = nil
                    self.requestIDs[scope] = nil
                }
            }
            do {
                try Task.checkCancellation()
                try await operation(self, progress)
                guard self.sessionGeneration == expected, self.requestIDs[scope] == requestID else { return }
                self.academicStates[scope, default: AcademicLoadState()].hasLoaded = true
                self.academicStates[scope, default: AcademicLoadState()].updatedAt = self.now()
            } catch {
                guard self.sessionGeneration == expected, self.requestIDs[scope] == requestID,
                      !self.isCancellation(error), !Task.isCancelled else { return }
                let message = (error as? AppError)?.errorDescription ?? "查询失败，请检查网络后重试"
                self.academicStates[scope, default: AcademicLoadState()].error = message
                if (error as? AppError) == .authenticationExpired { await self.handle(error) }
                // Keep errors local to the resource; don't interrupt other pages.
            }
        }
        academicTasks[scope] = task
        await task.value
    }

    private func receiveProgress(_ value: QueryProgress, scope: LoadingScope, requestID: UUID, generation: UUID) {
        guard sessionGeneration == generation, requestIDs[scope] == requestID else { return }
        academicStates[scope, default: AcademicLoadState()].progress = value
    }

    func changeTerm(to term: String) async {
        selectTerm(term)
        await loadSchedule(forceRefresh: true)
    }

    /// Validates, normalizes and persists the start date for one term.
    /// The date is merged into the existing `TermSettings` so presets and
    /// user entries keep working side by side.
    func setTermStartDate(_ raw: String, for term: String) async {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else {
            notice = AppNotice(message: "请先选择学期")
            return
        }
        guard !value.isEmpty else {
            notice = AppNotice(message: "请输入开学日期，格式为 2026-03-01")
            return
        }
        guard let date = ScheduleWeek.parseStartDate(value) else {
            notice = AppNotice(message: "开学日期格式无效，请使用 2026-03-01 格式")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ScheduleWeek.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var updated = termSettings
        updated.startDates[trimmedTerm] = formatter.string(from: date)
        // updateTermSettings validates the stored current term; keep it valid
        // even when the academic service has no current term yet.
        if AcademicHTMLParser.normalizeTerm(updated.currentTerm) == nil {
            updated.currentTerm = trimmedTerm
        }
        do {
            try await academicService.updateTermSettings(updated)
            termSettings = updated
            notice = AppNotice(message: "已保存 \(trimmedTerm) 开学日期")
        } catch {
            if isCancellation(error) { return }
            await handle(error)
        }
    }

    private func begin(_ scope: LoadingScope) {
        loadingScopes.insert(scope)
    }

    private func end(_ scope: LoadingScope) {
        loadingScopes.remove(scope)
    }

    private func updateSMSCooldown() {
        smsCooldown = max(0, Int(ceil(smsDeadline?.timeIntervalSince(now()) ?? 0)))
    }

    private func startSMSCooldown() {
        smsCooldownTask?.cancel()
        smsDeadline = now().addingTimeInterval(60)
        updateSMSCooldown()
        smsCooldownTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.updateSMSCooldown()
                if self.smsCooldown == 0 { return }
            }
        }
    }

    private func resumeWechatPollingIfNeeded() {
        guard appIsActive, loginMode == .wechat, !isAuthenticated, let state = wechatState else { return }
        guard state.status == .pending || state.status == .scanned || state.status == .bindRequired else {
            return
        }
        guard state.expiresAt > now() else {
            wechatState = WechatLoginState(
                state: state.state,
                url: state.url,
                status: .expired,
                message: "二维码已过期",
                expiresAt: state.expiresAt,
                user: state.user
            )
            return
        }
        wechatPollingTask?.cancel()
        let pollingID = wechatRequestID
        wechatPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.appIsActive, self.loginMode == .wechat, !self.isAuthenticated, self.wechatRequestID == pollingID, let current = self.wechatState else { return }
                guard current.expiresAt > self.now() else {
                    self.wechatState = WechatLoginState(
                        state: current.state,
                        url: current.url,
                        status: .expired,
                        message: "二维码已过期",
                        expiresAt: current.expiresAt,
                        user: current.user
                    )
                    return
                }
                do {
                    let updated = try await self.authService.pollWechatLogin(state: current)
                    guard !Task.isCancelled, self.wechatRequestID == pollingID, !self.isAuthenticated else { return }
                    self.wechatState = updated
                    if updated.status == .success, let user = updated.user {
                        self.wechatPollingTask = nil
                        self.wechatState = nil
                        self.sessionState = .signedIn(user)
                        Log.notice(.session, LogMessage("微信登录完成，进入主界面：{username}", sensitive: ["username": user.username]))
                        await self.loadTermSettings()
                        await self.loadInitialAcademicData()
                        return
                    }
                    if updated.status == .expired { return }
                } catch {
                    if self.isCancellation(error) { return }
                    if self.shouldRetryWechatPolling(after: error) { continue }
                    await self.handle(error)
                    return
                }
            }
        }
    }

    private func handle(_ error: Error) async {
        if isCancellation(error) { return }
        if let appError = error as? AppError {
            if case .authenticationExpired = appError {
                Log.notice(.session, LogMessage("登录状态失效，清除会话并回到登录页"))
                resetSessionData()
                sessionState = .signedOut
                await authService.logout()
                await academicService.clearCache()
                notice = AppNotice(message: appError.errorDescription ?? "登录状态已失效，请重新登录")
                await refreshCaptcha()
                return
            }
            Log.error(.ui, LogMessage("\(appError.errorDescription ?? "操作失败，请稍后重试")"))
            notice = AppNotice(message: appError.errorDescription ?? "操作失败，请稍后重试")
        } else {
            Log.error(.ui, LogMessage("未知错误：\(error.localizedDescription)"))
            notice = AppNotice(message: "操作失败，请检查网络后重试")
        }
    }

    private static func termSort(_ lhs: String, _ rhs: String) -> Bool {
        let l = lhs.replacingOccurrences(of: "-", with: "")
        let r = rhs.replacingOccurrences(of: "-", with: "")
        return l > r
    }

    private func nextTermStart(after startDate: Date) -> Date? {
        let calendar = ScheduleWeek.calendar
        let target = calendar.startOfDay(for: startDate)
        return termSettings.startDates.values
            .compactMap(ScheduleWeek.parseStartDate)
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 > target }
            .min()
    }

    private func termWindows() -> [(term: String, start: Date, window: Range<Date>)] {
        termSettings.startDates.compactMap { term, startText in
            guard let start = ScheduleWeek.parseStartDate(startText),
                  let window = ScheduleWeek.termWindow(startDate: start, nextStartDate: nextTermStart(after: start)) else { return nil }
            return (term.trimmingCharacters(in: .whitespacesAndNewlines), start, window)
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? AppError) == .requestCancelled
    }

    private func shouldRetryWechatPolling(after error: Error) -> Bool {
        guard let appError = error as? AppError else { return true }
        switch appError {
        case .requestTimedOut, .upstreamUnavailable, .invalidResponse:
            return true
        default:
            return false
        }
    }
}
