import XCTest
@testable import Better_Sicau

final class CookieJarTests: XCTestCase {
    func testDomainPathSecureAndExpiryMatching() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: [
            "sid=abc; Path=/xuesheng; Secure; Max-Age=120",
            "parent=yes; Domain=.sicau.edu.cn; Path=/; Max-Age=120",
            "expired=gone; Path=/; Max-Age=0",
        ], requestURL: URL(string: "https://jiaowu.sicau.edu.cn/xuesheng/kao")!, now: now)

        let matching = jar.header(for: URL(string: "https://jiaowu.sicau.edu.cn/xuesheng/kao")!, now: now)
        XCTAssertTrue(matching.contains("sid=abc"))
        XCTAssertTrue(matching.contains("parent=yes"))
        XCTAssertFalse(matching.contains("expired="))

        let outsidePath = jar.header(for: URL(string: "https://jiaowu.sicau.edu.cn/jiaoshi")!, now: now)
        XCTAssertFalse(outsidePath.contains("sid=abc"))
        XCTAssertTrue(outsidePath.contains("parent=yes"))

        let insecure = jar.header(for: URL(string: "http://jiaowu.sicau.edu.cn/xuesheng/kao")!, now: now)
        XCTAssertFalse(insecure.contains("sid=abc"))
    }

    func testCombinedSetCookieHeaderSplitsExpiresComma() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: [
            "a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT, b=2; Path=/",
        ], requestURL: URL(string: "https://example.com/path")!, now: now)

        let header = jar.header(for: URL(string: "https://example.com/path")!, now: now)
        XCTAssertTrue(header.contains("a=1"))
        XCTAssertTrue(header.contains("b=2"))
    }

    func testMaxAgeZeroAndNegativeDeleteCookie() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: ["keep=1; Path=/"], requestURL: URL(string: "https://example.com/")!, now: now)

        jar.set(from: ["keep=0; Max-Age=0"], requestURL: URL(string: "https://example.com/")!, now: now)

        XCTAssertFalse(jar.header(for: URL(string: "https://example.com/")!, now: now).contains("keep="))
    }

    func testExpiresPastDeletesCookie() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: ["sid=abc; Path=/"], requestURL: URL(string: "https://example.com/")!, now: now)

        jar.set(from: ["sid=x; Expires=Thu, 01 Jan 1970 00:00:00 GMT"], requestURL: URL(string: "https://example.com/")!, now: now)

        XCTAssertFalse(jar.header(for: URL(string: "https://example.com/")!, now: now).contains("sid="))
    }

    func testDefaultPathFollowsRFC6265DirectoryRule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        // 无 Path 时默认路径 = 请求路径最后一个 "/" 之前的目录
        jar.set(from: ["a=1"], requestURL: URL(string: "https://example.com/dir/page")!, now: now)

        XCTAssertTrue(jar.header(for: URL(string: "https://example.com/dir/page")!, now: now).contains("a=1"))
        XCTAssertTrue(jar.header(for: URL(string: "https://example.com/dir/other")!, now: now).contains("a=1"))
        XCTAssertFalse(jar.header(for: URL(string: "https://example.com/other")!, now: now).contains("a=1"))
    }

    func testHostOnlyCookieNotSentToSubdomains() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: ["hostonly=1; Path=/"], requestURL: URL(string: "https://jiaowu.sicau.edu.cn/")!, now: now)
        jar.set(from: ["domain=1; Domain=sicau.edu.cn; Path=/"], requestURL: URL(string: "https://jiaowu.sicau.edu.cn/")!, now: now)

        let subdomain = jar.header(for: URL(string: "https://webvpn.sicau.edu.cn/")!, now: now)
        XCTAssertFalse(subdomain.contains("hostonly="))
        XCTAssertTrue(subdomain.contains("domain=1"))
    }

    func testSameNameCookieIsOverwrittenByDomainPathKey() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: ["sid=first; Path=/"], requestURL: URL(string: "https://example.com/")!, now: now)
        jar.set(from: ["sid=second; Path=/"], requestURL: URL(string: "https://example.com/")!, now: now)

        let header = jar.header(for: URL(string: "https://example.com/")!, now: now)
        XCTAssertTrue(header.contains("sid=second"))
        XCTAssertFalse(header.contains("sid=first"))
    }

    func testLongerPathComesFirstInHeaderOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: ["a=root; Path=/"], requestURL: URL(string: "https://example.com/")!, now: now)
        jar.set(from: ["b=deep; Path=/xuesheng"], requestURL: URL(string: "https://example.com/")!, now: now)

        let header = jar.header(for: URL(string: "https://example.com/xuesheng/kao")!, now: now)
        let deepIndex = header.range(of: "b=deep")!.lowerBound
        let rootIndex = header.range(of: "a=root")!.lowerBound
        XCTAssertLessThan(deepIndex, rootIndex)
    }

    func testForeignDomainAttributeIsRejected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: ["evil=1; Domain=attacker.com; Path=/"], requestURL: URL(string: "https://jiaowu.sicau.edu.cn/")!, now: now)

        XCTAssertFalse(jar.header(for: URL(string: "https://jiaowu.sicau.edu.cn/")!, now: now).contains("evil="))
    }

    func testPersistedCookiesDropExpiredEntries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var jar = CookieJar()
        jar.set(from: [
            "fresh=1; Path=/; Max-Age=120",
            "rotten=1; Path=/; Max-Age=1",
        ], requestURL: URL(string: "https://example.com/")!, now: now)
        let later = now.addingTimeInterval(60)

        let persisted = jar.persistedCookies(at: later)
        XCTAssertEqual(persisted.map(\.name), ["fresh"])

        var restored = CookieJar(cookies: persisted, now: later)
        let header = restored.header(for: URL(string: "https://example.com/")!, now: later)
        XCTAssertTrue(header.contains("fresh=1"))
        XCTAssertFalse(header.contains("rotten="))
    }
}
