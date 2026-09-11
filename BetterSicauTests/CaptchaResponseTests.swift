import CommonCrypto
import XCTest
@testable import Better_Sicau

final class CaptchaResponseTests: XCTestCase {
    private struct LocalCaptchaSample: Decodable {
        var text: String
        var image: String
    }

    private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    override func tearDown() {
        CaptchaMockURLProtocol.reset()
        super.tearDown()
    }

    func testParsesActualTopLevelIDAndDataURLShape() throws {
        let payload: JSONValue = .object([
            "code": .number(200),
            "msg": .string("success"),
            "id": .string("captcha-123"),
            "requestId": .string("request-123"),
            "data": .string("  data:image/png;base64,\n\(pngData.base64EncodedString())  "),
        ])

        let challenge = try CaptchaResponseParser.parse(payload)

        XCTAssertEqual(challenge.uuid, "captcha-123")
        XCTAssertEqual(challenge.imageData, pngData)
    }

    func testParsesURLSafeUnpaddedBase64Image() throws {
        let encoded = pngData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payload: JSONValue = .object([
            "id": .string("captcha-url-safe"),
            "data": .string(encoded),
        ])

        let challenge = try CaptchaResponseParser.parse(payload)

        XCTAssertEqual(challenge.imageData, pngData)
    }

    func testDoesNotDecryptAlreadyDecodedDataURL() throws {
        let payload: JSONValue = .object([
            "id": .string("captcha-plain"),
            "requestId": .string("request-plain"),
            "data": .string("data:image/png;base64,\(pngData.base64EncodedString())"),
        ])

        let decoded = try CASResponseCrypto.decryptAuthResponse(payload)

        XCTAssertEqual(decoded, payload)
    }

    func testParsesNestedImageAliasAndNestedUUID() throws {
        let payload: JSONValue = .object([
            "code": .number(200),
            "data": .object([
                "uuid": .string("nested-uuid"),
                "image": .string(pngData.base64EncodedString()),
            ]),
        ])

        let challenge = try CaptchaResponseParser.parse(payload)

        XCTAssertEqual(challenge.uuid, "nested-uuid")
        XCTAssertEqual(challenge.imageData, pngData)
    }

    func testRejectsBase64PayloadThatIsNotAnImage() {
        let payload: JSONValue = .object([
            "id": .string("captcha-123"),
            "data": .string(Data("this is not an image".utf8).base64EncodedString()),
        ])

        XCTAssertThrowsError(try CaptchaResponseParser.parse(payload)) { error in
            XCTAssertEqual(error as? AppError, .invalidResponse("验证码响应图片格式无效"))
        }
    }

    func testRejectsNonImageDataURL() {
        let payload: JSONValue = .object([
            "id": .string("captcha-123"),
            "data": .string("data:text/plain;base64,SGVsbG8="),
        ])

        XCTAssertThrowsError(try CaptchaResponseParser.parse(payload)) { error in
            XCTAssertEqual(error as? AppError, .invalidResponse("验证码响应图片格式无效"))
        }
    }

    func testRejectsTruncatedImageData() {
        let payload: JSONValue = .object([
            "id": .string("captcha-123"),
            "data": .string(Data(pngData.prefix(24)).base64EncodedString()),
        ])

        XCTAssertThrowsError(try CaptchaResponseParser.parse(payload)) { error in
            XCTAssertEqual(error as? AppError, .invalidResponse("验证码响应图片格式无效"))
        }
    }

    func testRejectsMissingCaptchaIDSeparatelyFromImageFailure() {
        let payload: JSONValue = .object([
            "data": .string("data:image/png;base64,\(pngData.base64EncodedString())"),
        ])

        XCTAssertThrowsError(try CaptchaResponseParser.parse(payload)) { error in
            XCTAssertEqual(error as? AppError, .invalidResponse("验证码响应缺少标识"))
        }
    }

    func testDecryptsEncryptedCaptchaEnvelopeThenParses() throws {
        let requestID = "captcha-request-1"
        let plain = Data("\"data:image/png;base64,\(pngData.base64EncodedString())\"".utf8)
        let iv = Data(repeating: 0x31, count: kCCBlockSizeAES128)
        let key = CommonCryptoSupport.md5(Data("\(requestID):sicau-cas".utf8))
        let ciphertext = try encryptAES128CBC(plain, key: key, iv: iv)
        let envelope: JSONValue = .object([
            "code": .number(200),
            "id": .string("captcha-xyz"),
            "requestId": .string(requestID),
            "data": .string((iv + ciphertext).base64EncodedString()),
        ])

        let responseData = try JSONEncoder().encode(envelope)
        let responsePayload = try JSONDecoder().decode(JSONValue.self, from: responseData)
        let decrypted = try CASResponseCrypto.decryptAuthResponse(responsePayload)
        let challenge = try CaptchaResponseParser.parse(decrypted)

        XCTAssertEqual(challenge.uuid, "captcha-xyz")
        XCTAssertEqual(challenge.imageData, pngData)
    }

    func testRejectsMalformedEncryptedCaptchaEnvelope() {
        let envelope: JSONValue = .object([
            "code": .number(200),
            "id": .string("captcha-xyz"),
            "requestId": .string("captcha-request-1"),
            "data": .string("not-valid-base64"),
        ])

        XCTAssertThrowsError(try CASResponseCrypto.decryptAuthResponse(envelope)) { error in
            XCTAssertEqual(error as? AppError, .invalidResponse("认证响应加密数据无效"))
        }
    }

    func testFetchCaptchaReadsTopLevelIDAndEncryptedImageFromHTTPResponse() async throws {
        let requestID = "captcha-request-service"
        let plain = Data("\"data:image/png;base64,\(pngData.base64EncodedString())\"".utf8)
        let iv = Data(repeating: 0x42, count: kCCBlockSizeAES128)
        let key = CommonCryptoSupport.md5(Data("\(requestID):sicau-cas".utf8))
        let ciphertext = try encryptAES128CBC(plain, key: key, iv: iv)
        let envelope: JSONValue = .object([
            "code": .number(200),
            "msg": .string("success"),
            "id": .string("captcha-from-http"),
            "requestId": .string(requestID),
            "data": .string((iv + ciphertext).base64EncodedString()),
        ])
        CaptchaMockURLProtocol.configure([
            .init(status: 200, data: Data("{}".utf8)),
            .init(
                status: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                data: try JSONEncoder().encode(envelope)
            ),
        ])

        let session = makeMockSession()
        let challenge = try await session.fetchCaptcha()

        XCTAssertEqual(challenge.uuid, "captcha-from-http")
        XCTAssertEqual(challenge.imageData, pngData)
        let requests = CaptchaMockURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].url?.path.hasSuffix("/api/v1/captcha") == true)
        XCTAssertEqual(requests[1].url?.query, "vpn-12-o2-auth.sicau.edu.cn")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetchCaptchaSurfacesAPIErrorInsteadOfTreatingItAsOCRFailure() async {
        let failure: JSONValue = .object([
            "code": .number(503),
            "msg": .string("验证码服务暂不可用"),
        ])
        CaptchaMockURLProtocol.configure([
            .init(status: 200, data: Data("{}".utf8)),
            .init(
                status: 503,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                data: (try? JSONEncoder().encode(failure)) ?? Data()
            ),
        ])

        do {
            _ = try await makeMockSession().fetchCaptcha()
            XCTFail("Expected the captcha API error to be surfaced")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidResponse("验证码服务暂不可用"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCaptchaSurfacesBusinessErrorOnHTTP200() async {
        let failure: JSONValue = .object([
            "code": .number(401),
            "msg": .string("验证码参数已失效"),
            "id": .string("captcha-expired"),
            "requestId": .string("request-expired"),
            "data": .string("not-an-encrypted-image"),
        ])
        CaptchaMockURLProtocol.configure([
            .init(status: 200, data: Data("{}".utf8)),
            .init(
                status: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                data: (try? JSONEncoder().encode(failure)) ?? Data()
            ),
        ])

        do {
            _ = try await makeMockSession().fetchCaptcha()
            XCTFail("Expected the captcha business error to be surfaced")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidResponse("验证码参数已失效"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCaptchaCandidateNormalizationKeepsDigitsOnly() {
        XCTAssertEqual(CaptchaVisionRecognizer.normalizedCandidate(" ０9-A4３ "), "0943")
        XCTAssertEqual(CaptchaVisionRecognizer.normalizedCandidate("ABCD"), "")
        XCTAssertEqual(CaptchaVisionRecognizer.normalizedCandidate("12-345"), "12345")
    }

    @MainActor
    func testRefreshingCaptchaAutomaticallyRunsRecognition() async {
        let auth = CaptchaAuthServiceStub(
            challenge: CaptchaChallenge(uuid: "auto-recognition", imageData: pngData),
            recognition: CaptchaRecognition(text: "0472", confidence: 1)
        )
        let store = AppStore(authService: auth, academicService: CaptchaAcademicServiceStub())

        await store.refreshCaptcha()

        let recognitionCount = await auth.recognitionCount
        XCTAssertEqual(store.captchaChallenge?.uuid, "auto-recognition")
        XCTAssertEqual(store.captchaText, "0472")
        XCTAssertEqual(store.captchaRecognition?.text, "0472")
        XCTAssertEqual(recognitionCount, 1)
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testUncertainAutomaticRecognitionDoesNotFillCaptchaOrShowAlert() async {
        let auth = CaptchaAuthServiceStub(
            challenge: CaptchaChallenge(uuid: "uncertain-recognition", imageData: pngData),
            recognition: CaptchaRecognition(text: "", confidence: 1)
        )
        let store = AppStore(authService: auth, academicService: CaptchaAcademicServiceStub())

        await store.refreshCaptcha()

        XCTAssertEqual(store.captchaText, "")
        XCTAssertEqual(store.captchaRecognition?.text, "")
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testDelayedRecognitionDoesNotOverwriteManualInput() async {
        let auth = CaptchaAuthServiceStub(challenge: CaptchaChallenge(uuid: "delayed", imageData: pngData),
                                          recognition: CaptchaRecognition(text: "0472", confidence: 1))
        await auth.holdRecognition()
        let store = AppStore(authService: auth, academicService: CaptchaAcademicServiceStub())
        let request = Task { await store.refreshCaptcha() }
        await auth.waitForRecognition()
        store.captchaText = "1234"
        await auth.releaseRecognition()
        await request.value
        XCTAssertEqual(store.captchaText, "1234")
        XCTAssertEqual(store.captchaRecognition?.text, "0472")
    }

    func testLocalVisionSampleWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let encoded = environment["BETTER_SICAU_CAPTCHA_SAMPLE_BASE64"],
              let expected = environment["BETTER_SICAU_CAPTCHA_SAMPLE_TEXT"],
              let imageData = Data(base64Encoded: encoded) else {
            throw XCTSkip("Local captcha sample was not provided")
        }

        let result = try await CaptchaVisionRecognizer.recognize(imageData)

        XCTAssertEqual(result.text, expected)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.55)
    }

    func testLocalVisionSampleSetWhenProvided() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["BETTER_SICAU_CAPTCHA_SAMPLE_SET_BASE64"],
              let data = Data(base64Encoded: encoded),
              let samples = try? JSONDecoder().decode([LocalCaptchaSample].self, from: data),
              !samples.isEmpty else {
            throw XCTSkip("Local captcha sample set was not provided")
        }

        var correct = 0
        var incorrect = 0
        var results: [String] = []
        for sample in samples {
            guard let imageData = Data(base64Encoded: sample.image) else {
                results.append("\(sample.text)->invalid sample")
                continue
            }
            let probe = try await CaptchaVisionRecognizer.probe(imageData)
            let result = probe.recognition
            if result.text == sample.text { correct += 1 }
            else if !result.text.isEmpty { incorrect += 1 }
            let candidateText = probe.candidates.isEmpty ? "none" : probe.candidates.joined(separator: "|")
            results.append("\(sample.text)->\(result.text.isEmpty ? "empty" : result.text)[\(candidateText)]")
        }

        let accuracy = Double(correct) / Double(samples.count)
        XCTAssertGreaterThanOrEqual(accuracy, 0.70, results.joined(separator: ", "))
        XCTAssertEqual(incorrect, 0, results.joined(separator: ", "))
    }

    private func encryptAES128CBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            outputBytes.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "CaptchaResponseTests", code: Int(status))
        }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private func makeMockSession() -> SicauSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptchaMockURLProtocol.self]
        return SicauSession(
            networkConfiguration: NetworkConfiguration(timeout: 1, maxResponseBytes: 1_024 * 1_024, maxRedirects: 2),
            sessionConfiguration: configuration,
            keychainService: "cn.better.sicau.tests.captcha.\(UUID().uuidString)"
        )
    }
}

private final class CaptchaMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static var capturedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    static func configure(_ newStubs: [Stub]) {
        lock.withLock {
            stubs = newStubs
            requests = []
        }
    }

    static func reset() {
        configure([])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { () -> Stub? in
            Self.requests.append(request)
            return Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        }
        guard let stub,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.data.isEmpty { client?.urlProtocol(self, didLoad: stub.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CaptchaAuthServiceStub: AuthService {
    let challenge: CaptchaChallenge
    let recognition: CaptchaRecognition
    private(set) var recognitionCount = 0
    private var hold = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func holdRecognition() { hold = true }
    func waitForRecognition() async {
        if suspended != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func releaseRecognition() { suspended?.resume(); suspended = nil }


    init(challenge: CaptchaChallenge, recognition: CaptchaRecognition) {
        self.challenge = challenge
        self.recognition = recognition
    }

    func fetchCaptcha() async throws -> CaptchaChallenge { challenge }

    func recognizeCaptcha(_ challenge: CaptchaChallenge) async throws -> CaptchaRecognition {
        recognitionCount += 1
        if hold { await withCheckedContinuation { suspended = $0; waiter?.resume(); waiter = nil } }
        return recognition
    }

    func login(
        username: String,
        password: String,
        captcha: String,
        challenge: CaptchaChallenge,
        rememberPassword: Bool
    ) async throws -> UserProfile {
        throw AppError.unsupported("Not used by captcha tests")
    }

    func startWechatLogin() async throws -> WechatLoginState {
        throw AppError.unsupported("Not used by captcha tests")
    }

    func pollWechatLogin(state: WechatLoginState) async throws -> WechatLoginState {
        throw AppError.unsupported("Not used by captcha tests")
    }

    func sendSMSCode(phone: String, captcha: String, challenge: CaptchaChallenge) async throws {
        throw AppError.unsupported("Not used by captcha tests")
    }

    func loginWithSMS(phone: String, code: String) async throws -> UserProfile {
        throw AppError.unsupported("Not used by captcha tests")
    }

    func restoreSession() async -> UserProfile? { nil }
    func savedCredentials() async -> SavedCredentials? { nil }
    func clearSavedCredentials() async throws {}
    func logout() async {}
}

private struct CaptchaAcademicServiceStub: AcademicService {
    func fetchGrades(forceRefresh: Bool) async throws -> GradeSnapshot {
        GradeSnapshot(grades: [], rankings: GradeRankings())
    }

    func fetchExams(forceRefresh: Bool) async throws -> [ExamItem] { [] }
    func fetchSchedule(term: String, forceRefresh: Bool) async throws -> [ScheduleItem] { [] }
    func termSettings() async -> TermSettings { TermSettings(currentTerm: "", startDates: [:]) }
    func updateTermSettings(_ settings: TermSettings) async throws {}
    func clearCache() async {}
}
