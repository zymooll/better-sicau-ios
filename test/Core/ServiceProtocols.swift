import Foundation

protocol AuthService: Sendable {
    func fetchCaptcha() async throws -> CaptchaChallenge
    func recognizeCaptcha(_ challenge: CaptchaChallenge) async throws -> CaptchaRecognition
    func login(
        username: String,
        password: String,
        captcha: String,
        challenge: CaptchaChallenge,
        rememberPassword: Bool
    ) async throws -> UserProfile
    func startWechatLogin() async throws -> WechatLoginState
    func pollWechatLogin(state: WechatLoginState) async throws -> WechatLoginState
    func sendSMSCode(phone: String, captcha: String, challenge: CaptchaChallenge) async throws
    func loginWithSMS(phone: String, code: String) async throws -> UserProfile
    func restoreSession() async -> UserProfile?
    func savedCredentials() async -> SavedCredentials?
    func clearSavedCredentials() async throws
    func logout() async
}

protocol AcademicService: Sendable {
    func fetchGrades(forceRefresh: Bool) async throws -> GradeSnapshot
    func fetchExams(forceRefresh: Bool) async throws -> [ExamItem]
    func fetchSchedule(term: String, forceRefresh: Bool) async throws -> [ScheduleItem]
    func fetchGrades(forceRefresh: Bool, progress: AcademicProgress?) async throws -> GradeSnapshot
    func fetchExams(forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ExamItem]
    func fetchSchedule(term: String, forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ScheduleItem]
    func termSettings() async -> TermSettings
    func updateTermSettings(_ settings: TermSettings) async throws
    /// Drops all in-memory query caches. Must be called on logout and on
    /// session expiry so one account never sees another account's data.
    func clearCache() async
}

extension AcademicService {
    func fetchGrades(forceRefresh: Bool, progress: AcademicProgress?) async throws -> GradeSnapshot {
        await progress?(.running(["获取成绩与排名"], at: 0))
        return try await fetchGrades(forceRefresh: forceRefresh)
    }

    func fetchExams(forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ExamItem] {
        await progress?(.running(["获取考试安排"], at: 0))
        return try await fetchExams(forceRefresh: forceRefresh)
    }

    func fetchSchedule(term: String, forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ScheduleItem] {
        await progress?(.running(["获取课表"], at: 0))
        return try await fetchSchedule(term: term, forceRefresh: forceRefresh)
    }
}

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

protocol JiaowuGateway: Sendable {
    func ensureJiaowuSession() async throws
    func requestJiaowuText(
        path: String,
        method: HTTPMethod,
        body: Data?,
        headers: [String: String]
    ) async throws -> String
}

extension JiaowuGateway {
    func requestJiaowuText(path: String) async throws -> String {
        try await requestJiaowuText(path: path, method: .get, body: nil, headers: [:])
    }
}
