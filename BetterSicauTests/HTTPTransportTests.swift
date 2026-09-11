import XCTest
@testable import Better_Sicau

final class HTTPTransportTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testRejectsNonHTTPSRequests() async {
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "http://example.test/data")!)

        do {
            _ = try await transport.execute(request)
            XCTFail("Expected an HTTPS validation failure")
        } catch let error as AppError {
            XCTAssertEqual(error, .upstreamUnavailable("上游请求必须使用 HTTPS"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDoesNotAutomaticallyFollowRedirects() async throws {
        MockURLProtocol.configure(
            .response(
                status: 302,
                headers: ["Location": "https://example.test/next"],
                data: Data()
            )
        )
        let transport = makeTransport()
        let result = try await transport.execute(
            URLRequest(url: URL(string: "https://example.test/start")!)
        )

        XCTAssertEqual(result.status, 302)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(result.url.absoluteString, "https://example.test/start")
    }

    func testRejectsOversizedResponse() async {
        MockURLProtocol.configure(
            .response(status: 200, headers: [:], data: Data(repeating: 0x41, count: 8))
        )
        let transport = makeTransport(maxResponseBytes: 4)

        do {
            _ = try await transport.execute(
                URLRequest(url: URL(string: "https://example.test/large")!)
            )
            XCTFail("Expected an oversized-response failure")
        } catch let error as AppError {
            XCTAssertEqual(error, .upstreamUnavailable("上游响应内容过大"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapsTimeout() async {
        MockURLProtocol.configure(.failure(.timedOut))
        let transport = makeTransport()

        do {
            _ = try await transport.execute(
                URLRequest(url: URL(string: "https://example.test/timeout")!)
            )
            XCTFail("Expected a timeout")
        } catch let error as AppError {
            XCTAssertEqual(error, .requestTimedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapsTaskCancellation() async {
        MockURLProtocol.configure(.pending)
        let transport = makeTransport()
        let task = Task {
            try await transport.execute(
                URLRequest(url: URL(string: "https://example.test/pending")!)
            )
        }
        try? await Task.sleep(for: .milliseconds(25))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as AppError {
            XCTAssertEqual(error, .requestCancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTransport(maxResponseBytes: Int = 1_024) -> HTTPTransport {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        return HTTPTransport(
            configuration: NetworkConfiguration(
                timeout: 1,
                maxResponseBytes: maxResponseBytes,
                maxRedirects: 0
            ),
            sessionConfiguration: sessionConfiguration
        )
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior {
        case response(status: Int, headers: [String: String], data: Data)
        case failure(URLError.Code)
        case pending
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behavior: Behavior = .pending
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int {
        lock.withLock { requests }
    }

    static func configure(_ newBehavior: Behavior) {
        lock.withLock {
            behavior = newBehavior
            requests = 0
        }
    }

    static func reset() {
        configure(.pending)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.lock.withLock { () -> Behavior in
            Self.requests += 1
            return Self.behavior
        }

        switch current {
        case .response(let status, let headers, let data):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending:
            break
        }
    }

    override func stopLoading() {}
}
