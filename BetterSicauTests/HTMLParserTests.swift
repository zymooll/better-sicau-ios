import XCTest
@testable import Better_Sicau

final class HTMLParserTests: XCTestCase {
    func testGradesIgnoreNavigationAndDecodeCells() {
        let html = """
        <html><body>
        <table><tr><td>【成绩查询】</td><td>点击查询</td></tr></table>
        <table><tr><th>序</th><th>课程名称</th><th>教师</th><th>学分</th><th>学期</th><th>成绩</th></tr>
        <tr><td>1</td><td>高等数学&nbsp;A</td><td>张老师</td><td>4</td><td>2025-2026-1</td><td>92</td></tr></table>
        </body></html>
        """
        let grades = AcademicHTMLParser.parseGrades(html)
        XCTAssertEqual(grades.count, 1)
        XCTAssertEqual(grades.first?.course, "高等数学 A")
        XCTAssertEqual(grades.first?.score, "92")
        XCTAssertEqual(grades.first?.term, "2025-2026-1")
    }

    func testExamFallbackHandlesUnclosedRows() {
        let html = "<table><tr><th>课程</th><th>考试时间</th><th>考试教室</th>" +
            "<tr><td>英语</td><td>2026-01-10 09:00</td><td>A101</td></table>"
        let exams = AcademicHTMLParser.parseExams(html)
        XCTAssertEqual(exams.count, 1)
        XCTAssertEqual(exams.first?.course, "英语")
        XCTAssertEqual(exams.first?.location, "A101")
    }

    func testScheduleDetailSplitsLineBreaksAndWeekSuffix() {
        let html = """
        <table><tr><th>课程名称</th><th>上课时间</th><th>教室</th><th>教师</th><th>周次</th></tr>
        <tr><td>程序设计</td><td>1-1,2-3 单周<br>3-5,6-7 双周</td><td>A101<br>A202</td><td>李老师</td><td>1-16</td></tr></table>
        """
        let schedule = AcademicHTMLParser.parseSchedule(html)
        XCTAssertEqual(schedule.count, 2)
        XCTAssertEqual(schedule.map(\.dayOfWeek), [1, 3])
        XCTAssertTrue(schedule.allSatisfy { $0.teacher == "李老师" && !$0.weeks.isEmpty })
    }

    func testAuthenticationPageDetectionDoesNotRejectNormalContent() {
        XCTAssertTrue(AcademicHTMLParser.isAuthenticationPage("<form action=\"/login.asp\"><input name=\"user\"></form>"))
        XCTAssertTrue(AcademicHTMLParser.isAuthenticationPage("<a href=\"https://example.edu/auth/login?service=portal\">Sign in</a>"))
        XCTAssertFalse(AcademicHTMLParser.isAuthenticationPage("<html><title>成绩查询</title><table><tr><td>课程</td></tr></table></html>"))
        XCTAssertFalse(AcademicHTMLParser.isAuthenticationPage("<a href=\"/downloads/login-guide.pdf\">Guide</a>"))
        XCTAssertFalse(AcademicHTMLParser.isAuthenticationPage("<a href=\"/downloads/login/guide.pdf\">Guide</a>"))
        XCTAssertFalse(AcademicHTMLParser.isAuthenticationPage("<a href=\"/loginHelp\">Help</a>"))
        XCTAssertFalse(AcademicHTMLParser.isAuthenticationPage("<a href=\"/search?q=login\">Search</a>"))
    }

    func testGradeParserDoesNotReadExamTableAsGrades() {
        let html = """
        <html><title>考试安排</title><body>
        <table><tr><th>课程</th><th>考试时间</th><th>考试教室</th><th>座位号</th></tr>
        <tr><td>英语</td><td>2026-01-10 09:00</td><td>A101</td><td>12</td></tr></table>
        </body></html>
        """

        let grades = AcademicHTMLParser.parseGrades(html)
        XCTAssertTrue(grades.isEmpty)
        XCTAssertFalse(AcademicHTMLParser.isConfirmedGradePage(html, items: grades))
    }

    func testGradeParserDoesNotReadScheduleTableAsGrades() {
        let html = """
        <html><title>课表</title><body>
        <table><tr><th>课程名称</th><th>上课时间</th><th>教室</th><th>教师</th><th>周次</th></tr>
        <tr><td>程序设计</td><td>1-1,2-3</td><td>A101</td><td>李老师</td><td>1-16</td></tr></table>
        </body></html>
        """

        XCTAssertTrue(AcademicHTMLParser.parseGrades(html).isEmpty)
        XCTAssertFalse(AcademicHTMLParser.isConfirmedGradePage(
            html,
            items: [GradeItem(course: "程序设计", score: "99")]
        ))
    }

    func testConfirmedGradePageAcceptsExplicitEmptyGradeResult() {
        let html = """
        <html><title>成绩查询</title><body>
        <table><tr><th>课程</th><th>成绩</th><th>绩点</th></tr></table>
        <p>(0条)</p>
        </body></html>
        """

        XCTAssertTrue(AcademicHTMLParser.isConfirmedGradePage(html, items: []))
    }

    func testRankingParserDropsStatusFromDuplicateRankHeader() {
        let html = """
        <html><title>初修必修加权排名</title><body>
        <table><tr>
          <th>姓名</th><th>年级</th><th>学号</th><th>专业</th><th>班级</th>
          <th>初修必修加权成绩</th><th>专业排名</th><th>专业排名</th>
        </tr><tr>
          <td>曾一铭</td><td>2025</td><td>202501359</td><td>农业机械化及其自动化</td><td>农机202503</td>
          <td>85.44</td><td>53</td><td>在读情况</td>
        </tr></table>
        </body></html>
        """

        let ranking = AcademicHTMLParser.parseGradeRanking(html)
        XCTAssertTrue(ranking.metrics.contains { $0.label == "专业排名" && $0.value == "53" })
        XCTAssertFalse(ranking.metrics.contains { $0.label == "专业排名" && $0.value == "在读情况" })
        XCTAssertFalse(ranking.summary.contains("在读情况"))
    }

    func testGradeParserDoesNotReadCourseSelectionTableAsGrades() {
        let html = """
        <html><title>选课情况</title><body>
        <table><tr><th>序</th><th>课程</th><th>课程性质</th><th>教师</th><th>学分</th><th>上课时间</th><th>教室</th></tr>
        <tr><td>1</td><td>大学语文</td><td>任选</td><td>张老师</td><td>2</td><td>星期一 1-2</td><td>A101</td></tr></table>
        </body></html>
        """

        XCTAssertTrue(AcademicHTMLParser.parseGrades(html).isEmpty)
        XCTAssertFalse(AcademicHTMLParser.isConfirmedGradePage(html, items: []))
    }

    func testScheduleParserDoesNotReadGradeTableAsSchedule() {
        let html = """
        <html><title>成绩查询</title><body>
        <table><tr><th>序</th><th>课程名称</th><th>教师</th><th>学分</th><th>学期</th><th>成绩</th></tr>
        <tr><td>1</td><td>高等数学</td><td>张老师</td><td>4</td><td>2025-2026-1</td><td>92</td></tr></table>
        </body></html>
        """

        let schedule = AcademicHTMLParser.parseSchedule(html)
        XCTAssertEqual(schedule.count, 0, "unexpected schedule rows: \(schedule)")
    }

    func testScheduleParserDoesNotReadCourseSelectionTableAsSchedule() {
        let html = """
        <html><title>开课目录</title><body>
        <table><tr><th>课程名称</th><th>教师</th><th>学分</th><th>容量</th><th>余量</th><th>上课时间</th><th>教室</th><th>周次</th><th>操作</th></tr>
        <tr><td>大学语文</td><td>张老师</td><td>2</td><td>60</td><td>3</td><td>星期一 1-2</td><td>A101</td><td>1-16</td><td>选课</td></tr></table>
        </body></html>
        """

        let schedule = AcademicHTMLParser.parseSchedule(html)
        XCTAssertEqual(schedule.count, 0, "unexpected schedule rows: \(schedule)")
    }

    func testScheduleFallbackIgnoresRankingNavigationTable() {
        let html = """
        <table><tr><td>专业排名</td><td>点击查询</td><td>成绩单下载</td></tr></table>
        <table><tr><th>初修必修加权排名</th><th>专业总人数</th></tr><tr><td>3/40</td><td>40</td></tr></table>
        """

        XCTAssertTrue(AcademicHTMLParser.parseSchedule(html).isEmpty)
    }
}

final class LiveAcademicServiceTermTests: XCTestCase {
    func testScheduleRejectsDataWhenPostSwitchTermPageFails() async throws {
        try await assertScheduleRejected(
            postSwitchPage: .failure(.upstreamUnavailable("term state unavailable"))
        )
    }

    func testScheduleRejectsDataWhenPostSwitchTermPageIsBlank() async throws {
        try await assertScheduleRejected(postSwitchPage: .success("  \n\t"))
    }

    private func assertScheduleRejected(postSwitchPage: Result<String, AppError>) async throws {
        let gateway = TermSwitchGateway(postSwitchPage: postSwitchPage)
        let service = LiveAcademicService(gateway: gateway)

        do {
            _ = try await service.fetchSchedule(term: "2025-2026-1", forceRefresh: true)
            XCTFail("Unverified term must not be accepted")
        } catch {
            guard case .invalidResponse = error as? AppError else { return XCTFail("Unexpected error: \(error)") }
        }
        let scheduleRequestCount = await gateway.scheduleRequestCount
        XCTAssertEqual(scheduleRequestCount, 0)

    }

    func testNonemptyPostSwitchPageWithoutTermMarkerIsRejected() async throws {
        try await assertScheduleRejected(postSwitchPage: .success("<html><body>学期状态已刷新</body></html>"))
    }

    func testConfirmedSelectedTermCanBeCached() async throws {
        let gateway = TermSwitchGateway(postSwitchPage: .success("<select name='xueqi'><option selected value='2025-2026-1'>2025-2026-1</option></select>"))
        let service = LiveAcademicService(gateway: gateway, userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = try await service.fetchSchedule(term: "2025-2026-1", forceRefresh: true)
        let second = try await service.fetchSchedule(term: "2025-2026-1", forceRefresh: false)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second, first)
        let count = await gateway.scheduleRequestCount
        XCTAssertEqual(count, 1)
    }

}

private actor TermSwitchGateway: JiaowuGateway {
    let postSwitchPage: Result<String, AppError>
    private var courseSelectRequestCount = 0
    private(set) var scheduleRequestCount = 0

    init(postSwitchPage: Result<String, AppError>) {
        self.postSwitchPage = postSwitchPage
    }

    func ensureJiaowuSession() async throws {}

    func requestJiaowuText(
        path: String,
        method: HTTPMethod,
        body: Data?,
        headers: [String: String]
    ) async throws -> String {
        if path == "/xuesheng/gongxuan/gongxuan/bxq.asp" {
            courseSelectRequestCount += 1
            if courseSelectRequestCount == 1 {
                return "<html><body>开课目录</body></html>"
            }
            return try postSwitchPage.get()
        }
        if path.contains("xszhinan.asp") {
            return "<html><body>切换请求已接收</body></html>"
        }
        if path == "/xuesheng/gongxuan/gongxuan/zxian_rw_list.asp" {
            return "<html><body>在线教学</body></html>"
        }
        if path == "/xuesheng/gongxuan/gongxuan/kbbanji.asp?title_id1=4" {
            scheduleRequestCount += 1
            return Self.scheduleHTML
        }
        return ""
    }

    private static let scheduleHTML = """
    <table>
      <tr><th>课程名称</th><th>上课时间</th><th>教室</th><th>教师</th><th>周次</th></tr>
      <tr><td>高等数学</td><td>1-1,2-3</td><td>A101</td><td>张老师</td><td>1-16</td></tr>
    </table>
    """
}

final class AcademicProgressTests: XCTestCase {
    func testUnrelatedHTMLIsNotTreatedAsAnEmptyResult() {
        XCTAssertFalse(AcademicHTMLParser.isConfirmedExamPage("<h1>系统维护中</h1>", items: []))
        XCTAssertFalse(AcademicHTMLParser.isConfirmedEmptySchedulePage("<h1>教务首页</h1>"))
        XCTAssertTrue(AcademicHTMLParser.isConfirmedExamPage("<p>暂无考试安排</p>", items: []))
        XCTAssertTrue(AcademicHTMLParser.isConfirmedEmptySchedulePage("<p>暂无课表</p>"))
    }

    func testExamProgressFollowsActualSources() async throws {
        let gateway = ExamFlowGateway()
        let service = LiveAcademicService(gateway: gateway)
        let recorder = ProgressRecorder()
        let result = try await service.fetchExams(forceRefresh: true) { value in await recorder.append(value) }
        XCTAssertFalse(result.isEmpty)
        let steps = await recorder.messages
        XCTAssertEqual(steps, ["验证教务登录状态", "获取正考安排", "获取缓补考安排", "检查并合并考试数据"])
    }

    func testOneFailedExamSourceIsNotCachedAsComplete() async throws {
        let gateway = ExamFlowGateway()
        await gateway.setFailure(.requestTimedOut)
        let service = LiveAcademicService(gateway: gateway)
        do {
            _ = try await service.fetchExams(forceRefresh: true)
            XCTFail("Partial data must not be marked complete")
        } catch { XCTAssertEqual(error as? AppError, .requestTimedOut) }
        await gateway.setFailure(nil)
        _ = try await service.fetchExams(forceRefresh: false)
        let requests = await gateway.primaryCount
        XCTAssertEqual(requests, 2)
    }

    func testAuthenticationErrorInOneSourcePropagates() async {
        let gateway = ExamFlowGateway()
        await gateway.setFailure(.authenticationExpired)
        let service = LiveAcademicService(gateway: gateway)
        do {
            _ = try await service.fetchExams(forceRefresh: true)
            XCTFail("Authentication error must propagate")
        } catch { XCTAssertEqual(error as? AppError, .authenticationExpired) }
    }

    func testClearCacheInvalidatesInFlightOperation() async throws {
        let gateway = ExamFlowGateway()
        await gateway.holdNextPrimary()
        let service = LiveAcademicService(gateway: gateway)
        let task = Task { try await service.fetchExams(forceRefresh: true) }
        await gateway.waitUntilHeld()
        await service.clearCache()
        await gateway.release()
        do { _ = try await task.value; XCTFail("Old generation must be discarded") }
        catch { XCTAssertEqual(error as? AppError, .requestCancelled) }
        _ = try await service.fetchExams(forceRefresh: false)
        let count = await gateway.primaryCount
        XCTAssertEqual(count, 2)
    }
}

private actor ProgressRecorder {
    var messages: [String] = []
    func append(_ value: QueryProgress) { messages.append(value.message) }
}

private actor ExamFlowGateway: JiaowuGateway {
    var primaryCount = 0
    private var failure: AppError?
    private var hold = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func setFailure(_ error: AppError?) { failure = error }
    func holdNextPrimary() { hold = true }
    func waitUntilHeld() async {
        if suspended != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
    func ensureJiaowuSession() async throws {}
    func requestJiaowuText(path: String, method: HTTPMethod, body: Data?, headers: [String: String]) async throws -> String {
        if path.contains("xuesheng.asp") {
            primaryCount += 1
            if hold {
                hold = false
                await withCheckedContinuation { suspended = $0; observer?.resume(); observer = nil }
            }
        } else if let failure { throw failure }
        return "<table><tr><th>课程名称</th><th>考试时间</th><th>考试地点</th></tr><tr><td>高等数学</td><td>2026-12-20 09:00</td><td>A101</td></tr></table>"
    }
}
