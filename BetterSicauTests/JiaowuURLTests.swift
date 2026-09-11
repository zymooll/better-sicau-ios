import XCTest
@testable import Better_Sicau

final class JiaowuURLTests: XCTestCase {
    // MARK: - normalize

    func testNormalizeWebVPNPrefixStripsProxySegments() {
        let value = "https://webvpn.sicau.edu.cn/https/77726476706e69737468656265737421fafe409330252643770b88b9d65027203418e0/xuesheng/kao/kao/xuesheng.asp?title_id1=01"
        XCTAssertEqual(
            JiaowuURL.normalize(value),
            "/xuesheng/kao/kao/xuesheng.asp?title_id1=01"
        )
    }

    func testNormalizeJiaowuAbsoluteURL() {
        XCTAssertEqual(
            JiaowuURL.normalize("https://jiaowu.sicau.edu.cn/jiaoshi/aspsso/caslogin.asp"),
            "/jiaoshi/aspsso/caslogin.asp"
        )
    }

    func testNormalizeDecodesAmpersandEntities() {
        XCTAssertEqual(
            JiaowuURL.normalize("/xuesheng/kao?a=1&amp;b=2"),
            "/xuesheng/kao?a=1&b=2"
        )
    }

    func testNormalizeRelativePathGainsLeadingSlash() {
        XCTAssertEqual(JiaowuURL.normalize("xuesheng/kao.asp"), "/xuesheng/kao.asp")
        XCTAssertEqual(JiaowuURL.normalize(""), "/")
    }

    // MARK: - resolve

    func testResolveRelativeHrefAgainstBase() {
        XCTAssertEqual(
            JiaowuURL.resolve(basePath: "/xuesheng/chengji/chengji/chengji.asp", href: "sear_ch_all.asp"),
            "/xuesheng/chengji/chengji/sear_ch_all.asp"
        )
    }

    func testResolveParentTraversal() {
        XCTAssertEqual(
            JiaowuURL.resolve(basePath: "/a/b/c/page.asp", href: "../d/other.asp"),
            "/a/b/d/other.asp"
        )
    }

    func testResolveQueryOnlyHrefKeepsBasePath() {
        XCTAssertEqual(
            JiaowuURL.resolve(basePath: "/xuesheng/page.asp", href: "?xueqi=2025-2026-1"),
            "/xuesheng/page.asp?xueqi=2025-2026-1"
        )
    }

    func testResolveJavascriptHrefFallsBackToBase() {
        XCTAssertEqual(
            JiaowuURL.resolve(basePath: "/xuesheng/page.asp", href: "javascript:void(0)"),
            "/xuesheng/page.asp"
        )
    }

    func testResolveAbsoluteHrefWins() {
        XCTAssertEqual(
            JiaowuURL.resolve(basePath: "/xuesheng/page.asp", href: "/jiaoshi/caslogin.asp"),
            "/jiaoshi/caslogin.asp"
        )
    }

    // MARK: - 认证失效检测（与 AcademicHTMLParser 单测一致性由 AuthenticationDetectionTests 锁定）

    func testAuthenticationFailureDetectsLoginRedirectScript() {
        let html = "<html><script>window.location.href='index.asp';</script>登录超时</html>"
        XCTAssertTrue(JiaowuURL.isAuthenticationFailure(html))
    }

    func testAuthenticationFailureRejectsNormalContent() {
        let html = "<html><body><table><tr><td>课程</td><td>高等数学</td></tr></table></body></html>"
        XCTAssertFalse(JiaowuURL.isAuthenticationFailure(html))
    }
}
