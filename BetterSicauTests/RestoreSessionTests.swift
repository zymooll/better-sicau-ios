import XCTest
@testable import Better_Sicau

final class RestoreSessionTests: XCTestCase {
    private var service = ""

    override func setUp() {
        service = "RestoreSessionTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        RestoreMockURLProtocol.setHandler(nil)
        let keychain = KeychainStore(service: service)
        try? keychain.delete(SicauSession.sessionAccount)
        try? keychain.delete(SicauSession.credentialsAccount)
    }

    private func makeSession() -> SicauSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RestoreMockURLProtocol.self]
        return SicauSession(
            networkConfiguration: NetworkConfiguration(timeout: 5, maxResponseBytes: 1_000_000, maxRedirects: 3),
            sessionConfiguration: config,
            keychainService: service
        )
    }

    private func seedPersistedSession(username: String = "seeded-user") throws {
        let persisted = SicauSession.PersistedSession(
            version: 1,
            savedAt: Date(),
            cookies: [],
            user: UserProfile(username: username),
            webvpn: SicauSession.WebVPNState()
        )
        try KeychainStore(service: service).write(
            JSONEncoder().encode(persisted),
            account: SicauSession.sessionAccount
        )
    }

    func testRestoreKeepsSessionWhenNetworkIsDown() async throws {
        try seedPersistedSession()
        RestoreMockURLProtocol.setHandler(nil) // 模拟断网

        let profile = await makeSession().restoreSession()

        XCTAssertEqual(profile?.username, "seeded-user")
        // 会话数据必须仍在 Keychain（离线不得摧毁本地会话）
        XCTAssertNotNil(try KeychainStore(service: service).read(SicauSession.sessionAccount))
    }

    func testRestoreClearsSessionWhenUpstreamRejectsIt() async throws {
        try seedPersistedSession()
        RestoreMockURLProtocol.setHandler { _ in
            .init(status: 401, headers: ["Content-Type": "application/json"], data: Data())
        }

        let profile = await makeSession().restoreSession()

        XCTAssertNil(profile)
        XCTAssertNil(try KeychainStore(service: service).read(SicauSession.sessionAccount))
    }

    func testRestoreRefreshesUsernameWhenOnline() async throws {
        try seedPersistedSession(username: "stale-user")
        RestoreMockURLProtocol.setHandler { request in
            if request.url?.path == "/user/info" {
                return .init(status: 200, headers: ["Content-Type": "application/json"], data: Data(#"{"username":"fresh-user"}"#.utf8))
            }
            return .init(status: 200, headers: ["Content-Type": "application/json"], data: Data("{}".utf8))
        }

        let profile = await makeSession().restoreSession()

        XCTAssertEqual(profile?.username, "fresh-user")
    }

    func testRestoreRejectsCorruptedPayload() async throws {
        try KeychainStore(service: service).write(
            Data("not-json".utf8),
            account: SicauSession.sessionAccount
        )

        let profile = await makeSession().restoreSession()

        XCTAssertNil(profile)
        XCTAssertNil(try KeychainStore(service: service).read(SicauSession.sessionAccount))
    }
}

private final class RestoreMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var data: Data
    }

    private static let lock = NSLock()
    /// nil simulates a network failure.
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Response?)?

    static func setHandler(_ newHandler: ((URLRequest) -> Response?)?) {
        lock.withLock { handler = newHandler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let snapshot = Self.lock.withLock { Self.handler }
        guard let responseData = snapshot?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: responseData.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: responseData.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseData.data.isEmpty { client?.urlProtocol(self, didLoad: responseData.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
