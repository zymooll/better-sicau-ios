import XCTest
@testable import Better_Sicau

final class AuthenticationDetectionTests: XCTestCase {
    private let loginPage = """
    <html><head><title>统一认证</title></head><body>
    <form action="/login" method="post">
    <input type="text" name="username"><input type="password" name="password">
    </form>
    用户登录
    </body></html>
    """

    private let vpnAlertPage = """
    <html><head></head><body>
    <script>vpn_eval((function(){ alert('请重新登录') })())</script>
    <a href="index.asp">返回</a>
    </body></html>
    """

    private let gradePage = """
    <html><head><title>成绩查询</title></head><body>
    <table><tr><th>课程</th><th>成绩</th></tr><tr><td>高等数学</td><td>90</td></tr></table>
    </body></html>
    """

    func testLoginPageDetectedByBothImplementations() {
        XCTAssertTrue(AcademicHTMLParser.isAuthenticationPage(loginPage))
        XCTAssertTrue(JiaowuURL.isAuthenticationFailure(loginPage))
    }

    func testVPNAlertPageDetectedByBothImplementations() {
        XCTAssertTrue(AcademicHTMLParser.isAuthenticationPage(vpnAlertPage))
        XCTAssertTrue(JiaowuURL.isAuthenticationFailure(vpnAlertPage))
    }

    func testGradePageNotDetectedByEitherImplementation() {
        XCTAssertFalse(AcademicHTMLParser.isAuthenticationPage(gradePage))
        XCTAssertFalse(JiaowuURL.isAuthenticationFailure(gradePage))
    }

    func testBothImplementationsAgreeOnSharedFixtures() {
        for html in [loginPage, vpnAlertPage, gradePage, ""] {
            XCTAssertEqual(
                JiaowuURL.isAuthenticationFailure(html),
                AcademicHTMLParser.isAuthenticationPage(html)
            )
        }
    }
}
