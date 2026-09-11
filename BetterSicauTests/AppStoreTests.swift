import XCTest
@testable import Better_Sicau

@MainActor
final class AppStoreTests: XCTestCase {
    private var auth: MockAuthService!
    private var academic: MockAcademicService!
    private var store: AppStore!

    override func setUp() async throws {
        auth = MockAuthService()
        academic = MockAcademicService()
        store = AppStore(
            authService: auth,
            academicService: academic,
            defaults: UserDefaults(suiteName: "AppStoreTests.\(UUID().uuidString)")!
        )
    }

    func testLogoutClearsAcademicCache() async {
        await store.logout()

        XCTAssertEqual(academic.clearCacheCount, 1)
        XCTAssertEqual(auth.logoutCount, 1)
        XCTAssertEqual(store.sessionState, .signedOut)
    }

    func testAuthenticationExpiredClearsCacheAndSignsOut() async {
        auth.profile = UserProfile(username: "20240001")
        await store.bootstrap()
        XCTAssertTrue(store.isAuthenticated)

        academic.gradesResult = .failure(AppError.authenticationExpired)
        await store.loadGrades()

        XCTAssertEqual(academic.clearCacheCount, 1)
        XCTAssertEqual(auth.logoutCount, 1)
        XCTAssertEqual(store.sessionState, .signedOut)
        XCTAssertTrue(store.grades.isEmpty)
    }

    func testNonExpiryErrorKeepsSessionAndCache() async {
        auth.profile = UserProfile(username: "20240001")
        await store.bootstrap()
        XCTAssertTrue(store.isAuthenticated)

        academic.gradesResult = .failure(AppError.upstreamUnavailable("网络错误"))
        await store.loadGrades()

        XCTAssertEqual(academic.clearCacheCount, 0)
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertNotNil(store.state(for: .grades).error)
    }

    // MARK: - 学期与开学日期

    func testAvailableTermsIncludeGeneratedRangeSortedDescending() async {
        academic.termSettingsValue = TermSettings(currentTerm: "2025-2026-1", startDates: [:])
        await store.loadTermSettings()

        let terms = store.availableTerms

        XCTAssertTrue(terms.contains("2035-2036-2"))
        XCTAssertTrue(terms.contains("2025-2026-1"))
        XCTAssertEqual(terms.first, "2035-2036-2")
    }

    func testSetTermStartDateNormalizesAndPersists() async {
        academic.termSettingsValue = TermSettings(currentTerm: "2025-2026-1", startDates: [:])
        await store.loadTermSettings()

        await store.setTermStartDate("2026/3/1", for: "2025-2026-2")

        XCTAssertEqual(academic.lastUpdatedSettings?.startDates["2025-2026-2"], "2026-03-01")
        XCTAssertEqual(store.termSettings.startDates["2025-2026-2"], "2026-03-01")
        XCTAssertNotNil(store.notice)
    }

    func testSetTermStartDateRejectsInvalidDate() async {
        academic.termSettingsValue = TermSettings(currentTerm: "2025-2026-1", startDates: [:])
        await store.loadTermSettings()

        await store.setTermStartDate("not-a-date", for: "2025-2026-2")

        XCTAssertNil(academic.lastUpdatedSettings)
        XCTAssertNil(store.termSettings.startDates["2025-2026-2"])
        XCTAssertNotNil(store.notice)
    }

    func testSetTermStartDateFillsCurrentTermWhenMissing() async {
        academic.termSettingsValue = TermSettings(currentTerm: "", startDates: [:])
        await store.loadTermSettings()

        await store.setTermStartDate("2026-03-01", for: "2030-2031-1")

        XCTAssertEqual(academic.lastUpdatedSettings?.currentTerm, "2030-2031-1")
        XCTAssertEqual(academic.lastUpdatedSettings?.startDates["2030-2031-1"], "2026-03-01")
    }

    // MARK: - 考试窗口 fail-open

    func testVisibleExamsFailOpenWhenSelectedTermHasNoStartDate() async {
        academic.termSettingsValue = TermSettings(currentTerm: "2030-2031-1", startDates: [:])
        await store.loadTermSettings()

        let dated = ExamItem(course: "C1", time: "2030-06-20 09:00", term: "2030-2031-1")
        let noDate = ExamItem(course: "C2", time: "时间待定", term: "2030-2031-1")
        academic.examsResult = .success([dated, noDate])
        await store.loadExams()

        XCTAssertEqual(store.visibleExams.count, 2)
    }

    func testVisibleExamsPreservesSourceTermEvenOutsideDateWindows() async {
        academic.termSettingsValue = TermSettings(
            currentTerm: "2025-2026-1",
            startDates: ["2025-2026-1": "2025-09-01", "2025-2026-2": "2026-03-01"]
        )
        await store.loadTermSettings()

        let inside = ExamItem(course: "在窗口内", time: "2025-12-10 09:00", term: "2025-2026-1")
        let outside = ExamItem(course: "窗口外", time: "2030-06-01 09:00", term: "2025-2026-1")
        academic.examsResult = .success([inside, outside])
        await store.loadExams()

        XCTAssertEqual(store.visibleExams.map(\.course), ["在窗口内", "窗口外"])
    }

    func testVisibleExamsKeepsExamsOfUnknownTermEvenWhenOtherWindowsExist() async {
        academic.termSettingsValue = TermSettings(
            currentTerm: "2025-2026-1",
            startDates: ["2025-2026-1": "2025-09-01", "2025-2026-2": "2026-03-01"]
        )
        await store.loadTermSettings()
        store.selectTerm("2027-2028-1")

        let exam = ExamItem(course: "未来考试", time: "2027-12-10 09:00", term: "2027-2028-1")
        academic.examsResult = .success([exam])
        await store.loadExams()

        XCTAssertEqual(store.visibleExams.count, 1)
        XCTAssertEqual(store.examsForSelectedTerm.map(\.course), ["未来考试"])
    }
    func testUnknownExamRemainsVisibleInSelectedTerm() async {
        await store.loadTermSettings()
        academic.examsResult = .success([ExamItem(course: "未知", time: "待定")])
        await store.loadExams()
        XCTAssertEqual(store.examsForSelectedTerm.map(\.course), ["未知"])
    }

    func testClearCredentialsClearsMemoryPassword() async {
        store.username = "account"
        store.password = "password"
        store.rememberPassword = true
        await store.clearSavedCredentials()
        XCTAssertTrue(store.password.isEmpty)
        XCTAssertTrue(store.username.isEmpty)
        XCTAssertFalse(store.rememberPassword)
    }

    func testLatestTermWinsWhenEarlierResponseArrivesLast() async {
        let service = ControlledAcademicService()
        let store = makeControlledStore(service)
        store.selectTerm("2025-2026-1")
        let first = Task { await store.loadSchedule() }
        await service.waitForSchedule("2025-2026-1")
        store.selectTerm("2025-2026-2")
        let second = Task { await store.loadSchedule() }
        await service.waitForSchedule("2025-2026-2")
        await service.finishSchedule("2025-2026-2", course: "新学期")
        await second.value
        await service.finishSchedule("2025-2026-1", course: "旧学期")
        await first.value
        XCTAssertEqual(store.schedule.map(\.course), ["新学期"])
        XCTAssertFalse(store.isLoading(.schedule))
        XCTAssertNil(store.state(for: .schedule).error)
    }

    func testLogoutDiscardsDelayedSuccessAndProgress() async {
        let service = ControlledAcademicService()
        let store = makeControlledStore(service)
        store.sessionState = .signedIn(UserProfile(username: "old"))
        store.selectTerm("2025-2026-1")
        let request = Task { await store.loadSchedule() }
        await service.waitForSchedule("2025-2026-1")
        await store.logout()
        store.sessionState = .signedIn(UserProfile(username: "new"))
        await service.finishSchedule("2025-2026-1", course: "旧账号")
        await request.value
        XCTAssertTrue(store.schedule.isEmpty)
        XCTAssertFalse(store.state(for: .schedule).hasLoaded)
        XCTAssertNil(store.state(for: .schedule).progress)
        XCTAssertEqual(store.currentUser?.username, "new")
    }

    func testLogoutDiscardsDelayedAuthenticationError() async {
        let service = ControlledAcademicService()
        let store = makeControlledStore(service)
        store.selectTerm("2025-2026-1")
        let request = Task { await store.loadSchedule() }
        await service.waitForSchedule("2025-2026-1")
        await store.logout()
        store.sessionState = .signedIn(UserProfile(username: "new"))
        await service.failSchedule("2025-2026-1")
        await request.value
        XCTAssertEqual(store.currentUser?.username, "new")
        XCTAssertNil(store.state(for: .schedule).error)
    }

    func testProgressTracksServiceAndClearsOnCompletion() async {
        let service = ControlledAcademicService()
        let store = makeControlledStore(service)
        store.selectTerm("2025-2026-1")
        let request = Task { await store.loadSchedule() }
        await service.waitForSchedule("2025-2026-1")
        XCTAssertEqual(store.state(for: .schedule).progress?.message, "获取课程")
        XCTAssertEqual(store.state(for: .schedule).progress?.step, 2)
        await service.finishSchedule("2025-2026-1", course: "A")
        await request.value
        XCTAssertNil(store.state(for: .schedule).progress)
        XCTAssertTrue(store.state(for: .schedule).hasLoaded)
        XCTAssertNotNil(store.state(for: .schedule).updatedAt)
    }

    func testFailedRefreshKeepsPreviousData() async {
        academic.examsResult = .success([ExamItem(course: "已有考试")])
        await store.loadExams()
        academic.examsResult = .failure(AppError.requestTimedOut)
        await store.loadExams(forceRefresh: true)
        XCTAssertEqual(store.exams.map(\.course), ["已有考试"])
        XCTAssertTrue(store.state(for: .exams).hasLoaded)
        XCTAssertNotNil(store.state(for: .exams).error)
        XCTAssertFalse(store.isLoading(.exams))
    }

    func testHomeRefreshBypassesAllCaches() async {
        let service = ControlledAcademicService()
        await service.setImmediate()
        let store = makeControlledStore(service)
        store.sessionState = .signedIn(UserProfile(username: "test"))
        await store.refreshAll()
        let flags = await service.refreshFlags
        XCTAssertEqual(flags, [true, true, true])
    }

    func testSMSCooldownUsesDeadlineAfterReturningToForeground() async {
        var clock = ScheduleWeek.parseStartDate("2026-09-10")!
        let store = AppStore(authService: auth, academicService: academic,
                             defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { clock })
        await store.refreshCaptcha()
        store.phone = "13800000000"
        store.captchaText = "1234"
        await store.sendSMSCode()
        XCTAssertEqual(store.smsCooldown, 60)
        store.setAppActive(false)
        clock = clock.addingTimeInterval(75)
        store.setAppActive(true)
        XCTAssertEqual(store.smsCooldown, 0)
    }

    private func makeControlledStore(_ academic: ControlledAcademicService) -> AppStore {
        AppStore(authService: MockAuthService(), academicService: academic,
                 defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

}

private final class MockAuthService: AuthService, @unchecked Sendable {
    private let lock = NSLock()
    private var _profile: UserProfile?
    private var _logoutCount = 0

    var profile: UserProfile? {
        get { lock.lock(); defer { lock.unlock() }; return _profile }
        set { lock.lock(); defer { lock.unlock() }; _profile = newValue }
    }

    var logoutCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _logoutCount
    }

    private let captchaChallenge = CaptchaChallenge(uuid: "mock-captcha", imageData: Data())

    func fetchCaptcha() async throws -> CaptchaChallenge { captchaChallenge }

    func recognizeCaptcha(_ challenge: CaptchaChallenge) async throws -> CaptchaRecognition {
        CaptchaRecognition(text: "", confidence: 0)
    }

    func login(
        username: String,
        password: String,
        captcha: String,
        challenge: CaptchaChallenge,
        rememberPassword: Bool
    ) async throws -> UserProfile {
        throw AppError.unsupported("Not used by AppStore cache tests")
    }

    func startWechatLogin() async throws -> WechatLoginState {
        throw AppError.unsupported("Not used by AppStore cache tests")
    }

    func pollWechatLogin(state: WechatLoginState) async throws -> WechatLoginState {
        throw AppError.unsupported("Not used by AppStore cache tests")
    }

    func sendSMSCode(phone: String, captcha: String, challenge: CaptchaChallenge) async throws {
        // Successful synthetic SMS send; no network access.
    }

    func loginWithSMS(phone: String, code: String) async throws -> UserProfile {
        throw AppError.unsupported("Not used by AppStore cache tests")
    }

    func restoreSession() async -> UserProfile? { profile }
    func savedCredentials() async -> SavedCredentials? { nil }
    func clearSavedCredentials() async throws {}
    func logout() async {
        lock.withLock { _logoutCount += 1 }
    }
}

private final class MockAcademicService: AcademicService, @unchecked Sendable {
    private let lock = NSLock()
    private var _clearCacheCount = 0
    private var _gradesResult: Result<GradeSnapshot, Error> = .success(
        GradeSnapshot(grades: [], rankings: GradeRankings())
    )
    private var _examsResult: Result<[ExamItem], Error> = .success([])
    private var _scheduleResult: Result<[ScheduleItem], Error> = .success([])
    private var _termSettings = TermSettings(currentTerm: "2025-2026-1", startDates: [:])
    private var _lastUpdatedSettings: TermSettings?

    var clearCacheCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _clearCacheCount
    }

    var gradesResult: Result<GradeSnapshot, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _gradesResult }
        set { lock.lock(); defer { lock.unlock() }; _gradesResult = newValue }
    }

    var examsResult: Result<[ExamItem], Error> {
        get { lock.lock(); defer { lock.unlock() }; return _examsResult }
        set { lock.lock(); defer { lock.unlock() }; _examsResult = newValue }
    }

    var termSettingsValue: TermSettings {
        get { lock.lock(); defer { lock.unlock() }; return _termSettings }
        set { lock.lock(); defer { lock.unlock() }; _termSettings = newValue }
    }

    var lastUpdatedSettings: TermSettings? {
        lock.lock(); defer { lock.unlock() }
        return _lastUpdatedSettings
    }

    func fetchGrades(forceRefresh: Bool) async throws -> GradeSnapshot {
        try lock.withLock { _gradesResult }.get()
    }

    func fetchExams(forceRefresh: Bool) async throws -> [ExamItem] {
        try lock.withLock { _examsResult }.get()
    }

    func fetchSchedule(term: String, forceRefresh: Bool) async throws -> [ScheduleItem] {
        try lock.withLock { _scheduleResult }.get()
    }

    func termSettings() async -> TermSettings {
        lock.withLock { _termSettings }
    }

    func updateTermSettings(_ settings: TermSettings) async throws {
        lock.withLock {
            _termSettings = settings
            _lastUpdatedSettings = settings
        }
    }

    func clearCache() async {
        lock.withLock { _clearCacheCount += 1 }
    }
}


private actor ControlledAcademicService: AcademicService {
    private var pending: [String: CheckedContinuation<[ScheduleItem], Error>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var immediate = false
    private(set) var refreshFlags: [Bool] = []
    func setImmediate() { immediate = true }
    func waitForSchedule(_ term: String) async {
        if pending[term] != nil { return }
        await withCheckedContinuation { waiters[term] = $0 }
    }
    func finishSchedule(_ term: String, course: String) {
        pending.removeValue(forKey: term)?.resume(returning: [ScheduleItem(course: course, term: term)])
    }
    func failSchedule(_ term: String) {
        pending.removeValue(forKey: term)?.resume(throwing: AppError.authenticationExpired)
    }
    func fetchSchedule(term: String, forceRefresh: Bool) async throws -> [ScheduleItem] {
        try await fetchSchedule(term: term, forceRefresh: forceRefresh, progress: nil)
    }
    func fetchSchedule(term: String, forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ScheduleItem] {
        refreshFlags.append(forceRefresh)
        await progress?(.running(["确认学期", "获取课程", "整理课表"], at: 1))
        if immediate { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            pending[term] = continuation
            waiters.removeValue(forKey: term)?.resume()
        }
    }
    func fetchGrades(forceRefresh: Bool) async throws -> GradeSnapshot {
        refreshFlags.append(forceRefresh)
        return GradeSnapshot(grades: [], rankings: GradeRankings())
    }
    func fetchExams(forceRefresh: Bool) async throws -> [ExamItem] { refreshFlags.append(forceRefresh); return [] }
    func termSettings() async -> TermSettings { TermSettings(currentTerm: "2025-2026-1", startDates: [:]) }
    func updateTermSettings(_ settings: TermSettings) async throws {}
    func clearCache() async {}
}
