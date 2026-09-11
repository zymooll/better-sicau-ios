#if DEBUG
import Foundation
import SwiftUI

/// Isolated, synthetic data for simulator layout checks; never touches Keychain
/// or school servers. Disabled for real-device acceptance testing.
enum DebugFixtures {
    static var enabled: Bool { false }
    static var page: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-review"), arguments.indices.contains(index + 1) else { return "dashboard" }
        return arguments[index + 1]
    }
    @MainActor static func makeStore() -> AppStore {
        let service = PreviewServices(page: page)
        let defaults = UserDefaults(suiteName: "BetterSicau.UIReview")!
        defaults.removePersistentDomain(forName: "BetterSicau.UIReview")
        return AppStore(authService: service, academicService: service, defaults: defaults,
                        now: { ScheduleWeek.parseStartDate("2026-09-10")! })
    }
}

private actor PreviewServices: AuthService, AcademicService {
    let page: String
    private var scheduleCalls = 0
    init(page: String) { self.page = page }
    func savedCredentials() async -> SavedCredentials? { nil }
    func restoreSession() async -> UserProfile? { page == "login" ? nil : UserProfile(username: "演示账号") }
    func fetchCaptcha() async throws -> CaptchaChallenge { CaptchaChallenge(uuid: "preview", imageData: Data()) }
    func recognizeCaptcha(_ challenge: CaptchaChallenge) async throws -> CaptchaRecognition { CaptchaRecognition(text: "", confidence: 0) }
    func login(username: String, password: String, captcha: String, challenge: CaptchaChallenge, rememberPassword: Bool) async throws -> UserProfile { UserProfile(username: "演示账号") }
    func loginWithSMS(phone: String, code: String) async throws -> UserProfile { UserProfile(username: "演示账号") }
    func sendSMSCode(phone: String, captcha: String, challenge: CaptchaChallenge) async throws {}
    func startWechatLogin() async throws -> WechatLoginState { throw AppError.unsupported("演示模式不连接认证服务") }
    func pollWechatLogin(state: WechatLoginState) async throws -> WechatLoginState { state }
    func logout() async {}
    func clearSavedCredentials() async throws {}
    func clearCache() async {}
    func termSettings() async -> TermSettings { TermSettings(currentTerm: "2026-2027-1", startDates: ["2026-2027-1": "2026-09-07"]) }
    func updateTermSettings(_ settings: TermSettings) async throws {}
    func fetchGrades(forceRefresh: Bool) async throws -> GradeSnapshot {
        GradeSnapshot(grades: [GradeItem(course: "高等数学（一）", teacher: "王老师", credit: "4", term: "2026-2027-1", score: "92", gradePoint: "4.2")], rankings: GradeRankings())
    }
    func fetchExams(forceRefresh: Bool) async throws -> [ExamItem] {
        [ExamItem(course: "大学英语", time: "2026-12-20 09:00—11:00", location: "第一教学楼 A101", type: "正考", term: "2026-2027-1"),
         ExamItem(course: "线性代数", time: "时间待定", location: "待定", type: "缓补考")]
    }
    func fetchSchedule(term: String, forceRefresh: Bool) async throws -> [ScheduleItem] {
        try await fetchSchedule(term: term, forceRefresh: forceRefresh, progress: nil)
    }
    func fetchSchedule(term: String, forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ScheduleItem] {
        scheduleCalls += 1
        let steps = ["验证教务登录状态", "切换并确认学期", "查找课表入口", "读取课程安排", "整理课程与周次"]
        for index in steps.indices {
            await progress?(.running(steps, at: index))
            if page == "progress" { try await Task.sleep(for: .seconds(4)) }
        }
        if page == "error", scheduleCalls == 1 { throw AppError.requestTimedOut }
        return [
            ScheduleItem(course: "高等数学（一）", dayOfWeek: 1, sectionStart: 1, sectionEnd: 2, teacher: "王老师", location: "第一教学楼 A101", weeks: "1-16周", term: term),
            ScheduleItem(course: "大学物理实验", dayOfWeek: 1, sectionStart: 2, sectionEnd: 3, teacher: "李老师", location: "实验中心 B203", weeks: "1-16周（单）", term: term),
            ScheduleItem(course: "思想道德与法治", dayOfWeek: 2, sectionStart: 1, sectionEnd: 1, teacher: "陈老师", location: "第一教学楼 C301", weeks: "1-16周", term: term),
            ScheduleItem(course: "大学英语", dayOfWeek: 4, sectionStart: 3, sectionEnd: 4, teacher: "张老师", location: "第二教学楼 B202", weeks: "1-18周", term: term),
            ScheduleItem(course: "体育", dayOfWeek: 5, sectionStart: 7, sectionEnd: 8, location: "东区田径场", weeks: "1-16周", term: term),
            ScheduleItem(course: "社会实践与劳动教育", teacher: "辅导员", location: "自行安排", weeks: "1-20周", term: term)
        ]
    }
}
struct DebugPreviewAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if DebugFixtures.enabled && DebugFixtures.page == "large" {
            content.dynamicTypeSize(.accessibility3)
        } else if DebugFixtures.enabled && DebugFixtures.page == "dark" {
            content.preferredColorScheme(.dark)
        } else {
            content
        }
    }
}
#endif
