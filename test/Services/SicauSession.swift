import Foundation
import ImageIO

private enum SicauEndpoint {
    static let webvpnOrigin = "https://webvpn.sicau.edu.cn"
    static let authProxyPrefix = "\(webvpnOrigin)/https/77726476706e69737468656265737421f1e25594692361537f1dc7a99c406d36ef"
    static let defaultJiaowuRedirect = "/https/77726476706e69737468656265737421fafe409330252643770b88b9d65027203418e0/"
    static let webvpnAppID = "aea49a21-6b26-4e8f-bcfc-80e3de591c93"
    static let jiaowuAppID = "b54a2f27-f7ba-4b91-bbf0-3b2b12244d14"
    static let jiaowuCASService = "https://jiaowu.sicau.edu.cn/jiaoshi/aspsso/caslogin.asp"
    static let authMarker = "vpn-12-o2-auth.sicau.edu.cn"
    static let jiaowuVerificationPath = "/xuesheng/kao/kao/xuesheng.asp?title_id1=01"
}

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return Bool(value)
        default: return nil
        }
    }

    subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }
}

enum CASResponseCrypto {
    static func decryptAuthResponse(_ response: JSONValue) throws -> JSONValue {
        guard var object = response.objectValue,
              let encoded = object["data"]?.stringValue,
              let requestID = object["requestId"]?.stringValue else {
            return response
        }
        let compact = encoded.filter { !$0.isWhitespace }
        if compact.lowercased().hasPrefix("data:image/") {
            return response
        }
        guard !requestID.isEmpty,
              let raw = FlexibleBase64.decode(compact),
              raw.count > 16,
              (raw.count - 16).isMultiple(of: 16) else {
            throw AppError.invalidResponse("认证响应加密数据无效")
        }

        let key = Array(CommonCryptoSupport.md5(Data("\(requestID):sicau-cas".utf8)))
        let iv = Array(raw.prefix(16))
        let ciphertext = Array(raw.dropFirst(16))
        do {
            let plaintext = try CommonCryptoSupport.aes128CBCDecrypt(
                Data(ciphertext),
                key: Data(key),
                iv: Data(iv)
            )
            object["data"] = try JSONDecoder().decode(JSONValue.self, from: Data(plaintext))
            return .object(object)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.invalidResponse("认证响应解密失败")
        }
    }
}

private enum FlexibleBase64 {
    static func decode(_ value: String, maximumBytes: Int? = nil) -> Data? {
        var normalized = value
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }

        var suppliedPadding = 0
        while normalized.last == "=" {
            normalized.removeLast()
            suppliedPadding += 1
        }
        guard suppliedPadding <= 2,
              !normalized.contains("="),
              normalized.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 43, 47, 48...57, 65...90, 97...122: return true
                  default: return false
                  }
              }) else {
            return nil
        }

        let remainder = normalized.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        if let maximumBytes {
            let maximumEncodedLength = ((maximumBytes + 2) / 3) * 4
            guard normalized.utf8.count <= maximumEncodedLength else { return nil }
        }
        guard let data = Data(base64Encoded: normalized),
              maximumBytes.map({ data.count <= $0 }) ?? true else {
            return nil
        }
        return data
    }
}

enum CaptchaResponseParser {
    private static let maximumImageBytes = 4 * 1024 * 1024
    private static let maximumDimension = 4_096

    static func parse(_ payload: JSONValue) throws -> CaptchaChallenge {
        let imageString = firstString(payload, paths: [
            ["data"], ["data", "image"], ["data", "captcha"], ["data", "img"],
        ]) ?? ""
        let uuid = firstString(payload, paths: [["id"], ["uuid"], ["data", "uuid"]])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !uuid.isEmpty else { throw AppError.invalidResponse("验证码响应缺少标识") }
        guard !imageString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidResponse("验证码响应缺少图片数据")
        }
        guard let imageData = decodeImageData(imageString) else {
            throw AppError.invalidResponse("验证码响应图片格式无效")
        }
        return CaptchaChallenge(uuid: uuid, imageData: imageData)
    }

    private static func firstString(_ root: JSONValue, paths: [[String]]) -> String? {
        for path in paths {
            var value: JSONValue? = root
            for component in path {
                if let index = Int(component),
                   let array = value?.arrayValue,
                   array.indices.contains(index) {
                    value = array[index]
                } else {
                    value = value?[component]
                }
            }
            if let string = value?.stringValue,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    private static func decodeImageData(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let encoded: Substring
        if trimmed.lowercased().hasPrefix("data:") {
            guard let comma = trimmed.firstIndex(of: ",") else { return nil }
            let metadata = trimmed[..<comma].lowercased()
            let components = metadata.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard metadata.hasPrefix("data:image/"), components.contains("base64") else {
                return nil
            }
            encoded = trimmed[trimmed.index(after: comma)...]
        } else {
            encoded = trimmed[...]
        }

        guard let data = FlexibleBase64.decode(String(encoded), maximumBytes: maximumImageBytes),
              !data.isEmpty,
              isValidImage(data) else {
            return nil
        }
        return data
    }

    private static func isValidImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              image.width <= maximumDimension,
              image.height <= maximumDimension else {
            return false
        }
        return true
    }
}

enum JiaowuURL {
    static func normalize(_ value: String) -> String {
        let source = value.replacingOccurrences(of: "&amp;", with: "&")
        if let url = URL(string: source), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            if url.host?.lowercased() == "jiaowu.sicau.edu.cn" {
                return url.path + (url.query.map { "?\($0)" } ?? "")
            }
            if url.host?.lowercased() == "webvpn.sicau.edu.cn", url.path.hasPrefix("/https/") {
                let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
                if parts.count >= 4 {
                    return "/" + parts.dropFirst(3).joined(separator: "/") + (url.query.map { "?\($0)" } ?? "")
                }
            }
            return url.path + (url.query.map { "?\($0)" } ?? "")
        }
        if source.hasPrefix("/https/") {
            let parts = source.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count >= 4 { return "/" + parts.dropFirst(3).joined(separator: "/") }
        }
        return source.hasPrefix("/") ? source : "/\(source)"
    }

    static func resolve(basePath: String, href: String) -> String {
        let source = href.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty { return normalize(basePath) }
        if source.hasPrefix("/") || source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("//") {
            return normalize(source)
        }
        if source.lowercased().hasPrefix("javascript:") || source.lowercased().hasPrefix("mailto:") {
            return normalize(basePath)
        }

        let baseWithoutQuery = normalize(basePath).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        if source.hasPrefix("?") { return baseWithoutQuery + source }
        let baseDirectory = baseWithoutQuery.hasSuffix("/")
            ? baseWithoutQuery
            : String(baseWithoutQuery.dropLast(baseWithoutQuery.split(separator: "/").last?.count ?? 0))
        var output: [Substring] = []
        for part in "\(baseDirectory)\(source)".split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = output.popLast() }
            else { output.append(part) }
        }
        return "/" + output.joined(separator: "/")
    }

    /// Authentication-page detection lives in `AcademicHTMLParser` as the
    /// single source of truth. This wrapper keeps session verification and
    /// academic parsing from drifting apart — leave both call sites here.
    static func isAuthenticationFailure(_ html: String) -> Bool {
        AcademicHTMLParser.isAuthenticationPage(html)
    }
}

actor SicauSession: AuthService, JiaowuGateway {
    // Internal (not private) so @testable unit tests can seed and inspect
    // persisted state through KeychainStore.
    struct WebVPNState: Codable, Sendable {
        var redirect = ""
        var lastJiaowuPath = "/web/web/web/index.asp"
        var jiaowuReady = false
    }

    struct PersistedSession: Codable, Sendable {
        var version: Int
        var savedAt: Date
        var cookies: [StoredCookie]
        var user: UserProfile
        var webvpn: WebVPNState
    }

    static let sessionAccount = "better-sicau.session.v1"
    static let credentialsAccount = "better-sicau.credentials.v1"

    private let transport: HTTPTransport
    private let keychain: KeychainStore
    private let networkConfiguration: NetworkConfiguration
    private var generation = UUID()
    private var cookieJar = CookieJar()
    private var currentUser: UserProfile?
    private var webvpn = WebVPNState()
    private var currentCaptchaUUID = ""
    private var currentWechatState: WechatLoginState?
    private var smsPhone = ""

    init(
        networkConfiguration: NetworkConfiguration = NetworkConfiguration(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        keychainService: String = KeychainStore.defaultService
    ) {
        self.networkConfiguration = networkConfiguration
        self.transport = HTTPTransport(configuration: networkConfiguration, sessionConfiguration: sessionConfiguration)
        self.keychain = KeychainStore(service: keychainService)
    }

    func fetchCaptcha() async throws -> CaptchaChallenge {
        let expected = generation
        await primeWebvpnSession()
        try checkGeneration(expected)
        let response = try await perform(
            url: try makeURL("\(SicauEndpoint.authProxyPrefix)/api/v1/captcha?\(SicauEndpoint.authMarker)"),
            headers: ["Accept": "application/json"]
        )
        let payload = try parseAuthPayload(response, label: "验证码")
        try requireSuccessful(payload, status: response.status, fallback: "验证码加载失败")

        let challenge = try CaptchaResponseParser.parse(payload)
        currentCaptchaUUID = challenge.uuid
        Log.info(.auth, LogMessage("图形验证码获取成功（\(challenge.imageData.count) 字节）"))
        return challenge
    }

    func recognizeCaptcha(_ challenge: CaptchaChallenge) async throws -> CaptchaRecognition {
        try Task.checkCancellation()
        return try await CaptchaVisionRecognizer.recognize(challenge.imageData)
    }

    func login(
        username: String,
        password: String,
        captcha: String,
        challenge: CaptchaChallenge,
        rememberPassword: Bool
    ) async throws -> UserProfile {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let captcha = captcha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { throw AppError.validation("请输入账号和密码") }
        guard !captcha.isEmpty else { throw AppError.invalidCaptcha("请输入图形验证码") }
        guard !challenge.uuid.isEmpty, challenge.uuid == currentCaptchaUUID else {
            throw AppError.invalidCaptcha("验证码已过期，请刷新验证码后重试")
        }

        let body = try encodeJSON([
            "appid": SicauEndpoint.webvpnAppID,
            "number": username,
            "password": password,
            "code": captcha,
            "uuid": challenge.uuid,
        ])
        let response = try await performJSON(
            url: try makeURL("\(SicauEndpoint.authProxyPrefix)/api/v1/cas/login?\(SicauEndpoint.authMarker)"),
            body: body
        )
        let payload = try parseAuthPayload(response, label: "统一认证登录")
        do {
            try requireSuccessful(payload, status: response.status, fallback: "统一认证登录失败")
        } catch {
            throw mapAuthenticationError(error)
        }

        let profile = try await finishWebvpnLogin(payload: payload, fallbackUsername: username)
        if rememberPassword {
            do {
                try saveCredentials(SavedCredentials(username: username, password: password))
            } catch {
                Log.error(.storage, LogMessage("保存记住密码凭据失败：\(error.localizedDescription)"))
            }
        } else {
            deleteKeychainQuietly(Self.credentialsAccount, label: "已保存凭据")
        }
        Log.notice(.auth, LogMessage("密码登录成功：{username}", sensitive: ["username": username]))
        return profile
    }

    func startWechatLogin() async throws -> WechatLoginState {
        let expected = generation
        await primeWebvpnSession()
        try checkGeneration(expected)
        let body = try encodeJSON(["appid": SicauEndpoint.webvpnAppID, "cascallback": "wxlogined"])
        let response = try await performJSON(
            url: try makeURL("\(SicauEndpoint.authProxyPrefix)/api/v1/cas/getLoginQr?\(SicauEndpoint.authMarker)"),
            body: body
        )
        let payload = try parseAuthPayload(response, label: "微信扫码登录")
        try requireSuccessful(payload, status: response.status, fallback: "微信扫码登录初始化失败")
        guard let state = firstString(payload, paths: [["data", "state"], ["state"]]), !state.isEmpty,
              let urlString = firstString(payload, paths: [["data", "url"], ["url"]]),
              let url = URL(string: urlString) else {
            throw AppError.invalidResponse("微信扫码登录响应缺少二维码信息")
        }
        let loginState = WechatLoginState(
            state: state,
            url: url,
            status: .pending,
            message: "等待微信扫码确认",
            expiresAt: Date().addingTimeInterval(5 * 60),
            user: nil
        )
        currentWechatState = loginState
        Log.info(.auth, LogMessage("微信登录二维码已生成，等待扫码"))
        return loginState
    }

    func pollWechatLogin(state requested: WechatLoginState) async throws -> WechatLoginState {
        guard let active = currentWechatState, active.state == requested.state else {
            throw AppError.validation("微信扫码状态已失效，请刷新二维码")
        }
        if active.expiresAt <= Date() {
            let expired = WechatLoginState(
                state: active.state,
                url: active.url,
                status: .expired,
                message: "二维码已过期，请刷新",
                expiresAt: active.expiresAt,
                user: nil
            )
            currentWechatState = expired
            return expired
        }

        let body = try encodeJSON(["state": active.state])
        let response = try await performJSON(
            url: try makeURL("\(SicauEndpoint.authProxyPrefix)/api/v1/cas/getCasLoginQrRes?\(SicauEndpoint.authMarker)"),
            body: body
        )
        let payload = try parseAuthPayload(response, label: "微信扫码登录结果")
        let message = authMessage(payload, fallback: "等待微信扫码确认")

        if hasLoginTicket(payload) {
            try requireSuccessful(payload, status: response.status, fallback: "微信扫码登录失败")
            let profile = try await finishWebvpnLogin(payload: payload, fallbackUsername: "微信扫码用户")
            let success = WechatLoginState(
                state: active.state,
                url: active.url,
                status: .success,
                message: "登录成功",
                expiresAt: active.expiresAt,
                user: profile
            )
            currentWechatState = nil
            Log.notice(.auth, LogMessage("微信登录成功：{username}", sensitive: ["username": profile.username]))
            return success
        }

        let status: WechatLoginStatus
        let displayedMessage: String
        if firstValue(payload, path: ["data", "uuid"]) != nil
            || firstValue(payload, path: ["uuid"]) != nil
            || message.matches("record not found|未绑定|绑定|激活") {
            status = .bindRequired
            displayedMessage = message.lowercased() == "record not found"
                ? "该微信暂未绑定统一认证账号，请先完成账号绑定或激活"
                : message
            Log.notice(.auth, LogMessage("微信登录需绑定：\(displayedMessage)"))
        } else if firstValue(payload, path: ["data", "user"]) != nil || firstValue(payload, path: ["user"]) != nil {
            status = .scanned
            displayedMessage = "已扫码，请在手机端确认登录"
        } else {
            status = .pending
            displayedMessage = message
            Log.debug(.auth, LogMessage("微信登录轮询：\(message)"))
        }
        if response.status >= 400 || isFailurePayload(payload) {
            if status != .bindRequired { throw mapAuthenticationError(AppError.invalidResponse(message)) }
        }

        let next = WechatLoginState(
            state: active.state,
            url: active.url,
            status: status,
            message: displayedMessage,
            expiresAt: active.expiresAt,
            user: nil
        )
        currentWechatState = next
        return next
    }

    func sendSMSCode(phone: String, captcha: String, challenge: CaptchaChallenge) async throws {
        let phone = normalizePhone(phone)
        guard !phone.isEmpty else { throw AppError.validation("请输入正确的手机号码") }
        let captcha = captcha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captcha.isEmpty else { throw AppError.invalidCaptcha("请输入图形验证码") }
        guard challenge.uuid == currentCaptchaUUID, !challenge.uuid.isEmpty else {
            throw AppError.invalidCaptcha("验证码已过期，请刷新验证码后重试")
        }

        let body = try encodeJSON([
            "uuid": challenge.uuid,
            "code": captcha,
            "type": "login",
            "phone": phone,
        ])
        let response = try await performJSON(
            url: try makeURL("\(SicauEndpoint.authProxyPrefix)/api/v1/sms/send?\(SicauEndpoint.authMarker)"),
            body: body
        )
        let payload = try parseAuthPayload(response, label: "短信验证码")
        do {
            try requireSuccessful(payload, status: response.status, fallback: "短信验证码发送失败")
        } catch {
            throw mapAuthenticationError(error)
        }
        smsPhone = phone
        Log.info(.auth, LogMessage("短信验证码已发送：{phone}", sensitive: ["phone": phone]))
    }

    func loginWithSMS(phone: String, code: String) async throws -> UserProfile {
        let phone = normalizePhone(phone)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { throw AppError.validation("请输入正确的手机号码") }
        guard !code.isEmpty else { throw AppError.validation("请输入短信验证码") }
        if !smsPhone.isEmpty, smsPhone != phone { throw AppError.validation("请使用接收验证码的手机号码登录") }

        let body = try encodeJSON([
            "appid": SicauEndpoint.webvpnAppID,
            "phone": phone,
            "code": code,
        ])
        let response = try await performJSON(
            url: try makeURL("\(SicauEndpoint.authProxyPrefix)/api/v1/cas/loginByPhone?\(SicauEndpoint.authMarker)"),
            body: body
        )
        let payload = try parseAuthPayload(response, label: "短信验证码登录")
        do {
            try requireSuccessful(payload, status: response.status, fallback: "短信验证码登录失败")
        } catch {
            throw mapAuthenticationError(error)
        }
        let profile = try await finishWebvpnLogin(payload: payload, fallbackUsername: phone)
        Log.notice(.auth, LogMessage("短信登录成功：{phone}", sensitive: ["phone": phone]))
        return profile
    }

    func restoreSession() async -> UserProfile? {
        let expected = generation
        do {
            guard let data = try keychain.read(Self.sessionAccount) else {
                Log.info(.session, LogMessage("无已保存会话，进入未登录状态"))
                return nil
            }
            let restored = try JSONDecoder().decode(PersistedSession.self, from: data)
            guard restored.version == 1, !restored.user.username.isEmpty else {
                Log.notice(.session, LogMessage("已保存会话格式无效，清除"))
                deleteKeychainQuietly(Self.sessionAccount, label: "登录会话")
                return nil
            }
            cookieJar = CookieJar(cookies: restored.cookies)
            currentUser = restored.user
            webvpn = restored.webvpn
            webvpn.jiaowuReady = false

            do {
                let info = try await getWebvpnUserInfo()
                let username = userName(from: info) ?? restored.user.username
                let userType = userType(from: info) ?? restored.user.userType
                let profile = UserProfile(username: username, userType: userType, loggedInAt: restored.user.loggedInAt)
                currentUser = profile
                if webvpn.redirect.isEmpty { webvpn.redirect = try await getJiaowuRedirect() }
                Log.info(.session, LogMessage("会话恢复成功：{username}", sensitive: ["username": username]))
            } catch let error as AppError where error == .authenticationExpired {
                guard generation == expected, !Task.isCancelled else { return nil }
                // The upstream explicitly rejected the stored session.
                Log.notice(.session, LogMessage("上游拒绝已保存会话，清除本地登录状态"))
                clearInMemorySession()
                deleteKeychainQuietly(Self.sessionAccount, label: "登录会话")
                return nil
            } catch {
                guard generation == expected, !Task.isCancelled else { return nil }
                // Offline starts and transient upstream failures must not
                // destroy a locally valid session. Restore it anyway; the
                // first real jiaowu request surfaces any actual problem and
                // AppStore.handle deals with authenticationExpired there.
                Log.notice(.session, LogMessage("网络不可用，保留本地会话离线恢复：\(error.localizedDescription)"))
                webvpn.jiaowuReady = false
                if webvpn.redirect.isEmpty { webvpn.redirect = SicauEndpoint.defaultJiaowuRedirect }
            }
            try checkGeneration(expected)
            persistSessionQuietly()
            return currentUser
        } catch {
            guard generation == expected, !Task.isCancelled else { return nil }
            Log.error(.session, LogMessage("恢复会话失败（本地数据损坏）：\(error.localizedDescription)"))
            clearInMemorySession()
            deleteKeychainQuietly(Self.sessionAccount, label: "登录会话")
            return nil
        }
    }

    func savedCredentials() async -> SavedCredentials? {
        do {
            guard let data = try keychain.read(Self.credentialsAccount) else { return nil }
            let value = try JSONDecoder().decode(SavedCredentials.self, from: data)
            return value.username.isEmpty || value.password.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    func clearSavedCredentials() async throws {
        try keychain.delete(Self.credentialsAccount)
    }

    func logout() async {
        Log.info(.session, LogMessage("退出登录，清理会话数据"))
        clearInMemorySession()
        deleteKeychainQuietly(Self.sessionAccount, label: "登录会话")
    }

    func ensureJiaowuSession() async throws {
        let expected = generation
        if webvpn.jiaowuReady { return }
        guard currentUser != nil, !webvpn.redirect.isEmpty else { throw AppError.authenticationExpired }

        for attempt in 0..<3 {
            if try await verifyJiaowuSession() {
                try checkGeneration(expected)
                webvpn.jiaowuReady = true
                persistSessionQuietly()
                return
            }
            Log.debug(.session, LogMessage("教务会话校验失败，尝试 CAS 登录（第 \(attempt + 1) 次）"))
            do {
                try await loginJiaowuCASViaWebvpn()
            } catch let error as AppError where error == .requestCancelled {
                throw error
            } catch {
                try checkGeneration(expected)
                Log.debug(.session, LogMessage("教务 CAS 登录失败，走 SSO 入口回退：\(error.localizedDescription)"))
                // The SSO entry fallback below can still establish the ASP session.
            }
            if try await verifyJiaowuSession() {
                try checkGeneration(expected)
                webvpn.jiaowuReady = true
                persistSessionQuietly()
                return
            }
            _ = try? await requestJiaowuRaw(path: "/jiaoshi/aspsso/caslogin.asp", method: .get, body: nil, headers: [:])
            if try await verifyJiaowuSession() {
                try checkGeneration(expected)
                webvpn.jiaowuReady = true
                persistSessionQuietly()
                return
            }
        }
        webvpn.jiaowuReady = false
        Log.error(.session, LogMessage("教务会话建立失败（3 次尝试后仍无效）"))
        throw AppError.authenticationExpired
    }

    func requestJiaowuText(
        path: String,
        method: HTTPMethod,
        body: Data?,
        headers: [String: String]
    ) async throws -> String {
        let response = try await requestJiaowuRaw(path: path, method: method, body: body, headers: headers)
        guard response.status < 400 else {
            if response.status == 401 || response.status == 403 { throw AppError.authenticationExpired }
            throw AppError.upstreamUnavailable("教务请求失败（HTTP \(response.status)）")
        }
        return response.text
    }

    private func finishWebvpnLogin(payload: JSONValue, fallbackUsername: String) async throws -> UserProfile {
        let expected = generation
        guard let ticket = loginTicket(payload),
              let userID = firstString(payload, paths: userIDPaths),
              !ticket.isEmpty, !userID.isEmpty else {
            throw AppError.invalidResponse(authMessage(payload, fallback: "登录响应缺少 ST 或 userId"))
        }

        var callback = URLComponents(string: "\(SicauEndpoint.webvpnOrigin)/login")
        callback?.queryItems = [
            URLQueryItem(name: "cas_login", value: "true"),
            URLQueryItem(name: "ticket", value: "\(ticket):\(userID)"),
            URLQueryItem(name: "userId", value: userID),
        ]
        guard let callbackURL = callback?.url else { throw AppError.invalidResponse("登录回调地址无效") }
        _ = try await perform(url: callbackURL, followRedirects: true)

        let info = try await getWebvpnUserInfo()
        let redirect = try await getJiaowuRedirect()
        let profile = UserProfile(
            username: userName(from: info) ?? fallbackUsername,
            userType: userType(from: info) ?? "",
            loggedInAt: Date()
        )
        try checkGeneration(expected)
        currentUser = profile
        webvpn.redirect = redirect
        webvpn.jiaowuReady = false
        do {
            try await loginJiaowuCASViaWebvpn()
        } catch let error as AppError where error == .requestCancelled {
            throw error
        } catch {
            try checkGeneration(expected)
            webvpn.jiaowuReady = false
        }
        try checkGeneration(expected)
        try persistSession()
        return profile
    }

    private func loginJiaowuCASViaWebvpn() async throws {
        guard !webvpn.redirect.isEmpty else { throw AppError.authenticationExpired }
        let urls = [
            "\(SicauEndpoint.authProxyPrefix)/api/v1/cas/login?appid=\(SicauEndpoint.jiaowuAppID)&\(SicauEndpoint.authMarker)",
            "\(SicauEndpoint.authProxyPrefix)/api/v1/cas/login?\(SicauEndpoint.authMarker)&appid=\(SicauEndpoint.jiaowuAppID)",
        ]
        var lastError: Error = AppError.upstreamUnavailable("教务 CAS ready-login 失败")
        for value in urls {
            do {
                let response = try await perform(
                    url: try makeURL(value),
                    headers: ["Accept": "application/json"],
                    followRedirects: true
                )
                let payload = try parseAuthPayload(response, label: "教务 CAS ready-login")
                try requireSuccessful(payload, status: response.status, fallback: "教务 CAS ready-login 失败")
                guard let ticket = loginTicket(payload),
                      let userID = firstString(payload, paths: userIDPaths) else {
                    throw AppError.invalidResponse("教务 CAS ready-login 未返回 ST 或 userId")
                }
                let callbackURL = firstString(payload, paths: [["data", "callbackUrl"], ["callbackUrl"]]) ?? SicauEndpoint.jiaowuCASService
                try await callbackJiaowuCAS(callbackURL: callbackURL, ticket: ticket, userID: userID)
                return
            } catch let error as AppError where error == .requestCancelled {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func callbackJiaowuCAS(callbackURL: String, ticket: String, userID: String) async throws {
        guard var components = URLComponents(string: callbackURL) else {
            throw AppError.invalidResponse("教务 CAS 回调地址无效")
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "ticket" || $0.name == "userId" }
        queryItems.append(URLQueryItem(name: "ticket", value: "\(ticket):\(userID)"))
        queryItems.append(URLQueryItem(name: "userId", value: userID))
        components.queryItems = queryItems
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        _ = try await perform(
            url: try buildWebvpnURL(redirect: webvpn.redirect, path: path),
            headers: ["Referer": try buildWebvpnURL(redirect: webvpn.redirect, path: "/web/web/web/index.asp").absoluteString],
            followRedirects: true
        )
    }

    private func verifyJiaowuSession() async throws -> Bool {
        do {
            let response = try await requestJiaowuRaw(
                path: SicauEndpoint.jiaowuVerificationPath,
                method: .get,
                body: nil,
                headers: [:]
            )
            return response.status < 400 && !JiaowuURL.isAuthenticationFailure(response.text)
        } catch let error as AppError where error == .requestCancelled || error == .requestTimedOut {
            throw error
        } catch {
            return false
        }
    }

    private func requestJiaowuRaw(
        path: String,
        method: HTTPMethod,
        body: Data?,
        headers: [String: String]
    ) async throws -> HTTPResult {
        guard !webvpn.redirect.isEmpty else { throw AppError.authenticationExpired }
        let normalizedPath = JiaowuURL.normalize(path)
        let referer = try buildWebvpnURL(redirect: webvpn.redirect, path: webvpn.lastJiaowuPath).absoluteString
        var requestHeaders = headers
        if requestHeaders.keys.allSatisfy({ $0.caseInsensitiveCompare("Referer") != .orderedSame }) {
            requestHeaders["Referer"] = referer
        }
        let response = try await perform(
            url: try buildWebvpnURL(redirect: webvpn.redirect, path: normalizedPath),
            method: method,
            body: body,
            headers: requestHeaders,
            followRedirects: true
        )
        webvpn.lastJiaowuPath = normalizedPath
        if currentUser != nil { persistSessionQuietly() }
        return response
    }

    private func getWebvpnUserInfo() async throws -> JSONValue {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let response = try await perform(
            url: try makeURL("\(SicauEndpoint.webvpnOrigin)/user/info?_t=\(timestamp)"),
            headers: ["Accept": "application/json"]
        )
        if response.status == 401 || response.status == 403 || (300..<400).contains(response.status) {
            throw AppError.authenticationExpired
        }
        if (200..<300).contains(response.status),
           (response.headers["content-type"] ?? "").lowercased().hasPrefix("text/html"),
           response.text.matches("(?:href|action)\\s*=\\s*['\"][^'\"]*/login\\b|用户登录|统一认证|账号登录") {
            throw AppError.authenticationExpired
        }
        guard response.status < 400 else { throw AppError.upstreamUnavailable("用户信息读取失败") }
        let info = try parsePlainPayload(response, label: "用户信息")
        guard userName(from: info) != nil else { throw AppError.authenticationExpired }
        return info
    }

    private func getJiaowuRedirect() async throws -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let response = try await perform(
            url: try makeURL("\(SicauEndpoint.webvpnOrigin)/user/portal_groups?_t=\(timestamp)"),
            headers: ["Accept": "application/json"]
        )
        guard response.status < 400 else { throw AppError.upstreamUnavailable("门户列表读取失败") }
        let payload = try parsePlainPayload(response, label: "门户列表")
        let candidates = flattenPortalItems(payload)
        let match = candidates.first { item in
            let detail = item["detail"]?.stringValue ?? item["url"]?.stringValue ?? ""
            let name = item["name"]?.stringValue ?? ""
            return detail.localizedCaseInsensitiveContains("jiaowu.sicau.edu.cn") || name.contains("教务")
        }
        return match?["redirect"]?.stringValue ?? SicauEndpoint.defaultJiaowuRedirect
    }

    private func primeWebvpnSession() async {
        do {
            _ = try await perform(url: try makeURL(SicauEndpoint.webvpnOrigin), followRedirects: true)
        } catch let error as AppError where error == .requestCancelled {
            return
        } catch {
            return
        }
    }

    private func performJSON(url: URL, body: Data) async throws -> HTTPResult {
        try await perform(
            url: url,
            method: .post,
            body: body,
            headers: ["Content-Type": "application/json;charset=utf-8", "Accept": "application/json"]
        )
    }

    private func perform(
        url: URL,
        method: HTTPMethod = .get,
        body: Data? = nil,
        headers: [String: String] = [:],
        followRedirects: Bool = false
    ) async throws -> HTTPResult {
        let expected = generation
        var currentURL = url
        var currentMethod = method
        var currentBody = body
        var currentHeaders = headers

        for redirectCount in 0...networkConfiguration.maxRedirects {
            try Task.checkCancellation()
            var request = URLRequest(url: currentURL)
            request.httpMethod = currentMethod.rawValue
            request.httpBody = currentBody
            request.setValue("Mozilla/5.0 Better-Sicau-iOS/1.0", forHTTPHeaderField: "User-Agent")
            for (key, value) in currentHeaders { request.setValue(value, forHTTPHeaderField: key) }
            if let currentBody { request.setValue(String(currentBody.count), forHTTPHeaderField: "Content-Length") }
            let cookieHeader = cookieJar.header(for: currentURL)
            if !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }

            let response = try await transport.execute(request)
            try checkGeneration(expected)
            cookieJar.set(from: response.setCookieHeaders, requestURL: currentURL)
            if currentUser != nil { persistSessionQuietly() }

            guard followRedirects,
                  [301, 302, 303, 307, 308].contains(response.status),
                  let location = response.headers["location"], !location.isEmpty else {
                return response
            }
            guard redirectCount < networkConfiguration.maxRedirects else {
                throw AppError.upstreamUnavailable("上游重定向次数过多")
            }
            currentURL = try mapRedirect(location: location, currentURL: currentURL)
            if response.status == 303 {
                currentMethod = .get
                currentBody = nil
                currentHeaders = currentHeaders.filter { key, _ in
                    !["content-type", "content-length"].contains(key.lowercased())
                }
            }
        }
        throw AppError.upstreamUnavailable("上游重定向次数过多")
    }

    private func mapRedirect(location: String, currentURL: URL) throws -> URL {
        guard let resolved = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
            throw AppError.invalidResponse("上游重定向地址无效")
        }
        switch resolved.host?.lowercased() {
        case "jiaowu.sicau.edu.cn":
            return try buildWebvpnURL(
                redirect: webvpn.redirect,
                path: resolved.path + (resolved.query.map { "?\($0)" } ?? "")
            )
        case "auth.sicau.edu.cn":
            var query = resolved.query.map { "?\($0)" } ?? ""
            if !query.contains(SicauEndpoint.authMarker) {
                query += query.isEmpty ? "?\(SicauEndpoint.authMarker)" : "&\(SicauEndpoint.authMarker)"
            }
            return try makeURL("\(SicauEndpoint.authProxyPrefix)\(resolved.path)\(query)")
        default:
            guard resolved.scheme?.lowercased() == "https" else {
                throw AppError.upstreamUnavailable("上游重定向必须使用 HTTPS")
            }
            return resolved
        }
    }

    private func buildWebvpnURL(redirect: String, path: String) throws -> URL {
        let redirect = redirect.isEmpty ? SicauEndpoint.defaultJiaowuRedirect : redirect
        let prefix = redirect.hasSuffix("/") ? redirect : "\(redirect)/"
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return try makeURL("\(SicauEndpoint.webvpnOrigin)\(prefix)\(path)")
    }

    private func parsePlainPayload(_ response: HTTPResult, label: String) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: response.data)
        } catch {
            throw AppError.invalidResponse("\(label)响应不是有效 JSON（HTTP \(response.status)）")
        }
    }

    private func parseAuthPayload(_ response: HTTPResult, label: String) throws -> JSONValue {
        let plain = try parsePlainPayload(response, label: label)
        if response.status >= 400 || isFailurePayload(plain) {
            return (try? CASResponseCrypto.decryptAuthResponse(plain)) ?? plain
        }
        return try CASResponseCrypto.decryptAuthResponse(plain)
    }

    private func requireSuccessful(_ payload: JSONValue, status: Int, fallback: String) throws {
        guard status < 400, !isFailurePayload(payload) else {
            throw AppError.invalidResponse(authMessage(payload, fallback: fallback))
        }
    }

    private func isFailurePayload(_ payload: JSONValue) -> Bool {
        let code = firstString(payload, paths: [["code"], ["status"], ["errcode"], ["errorCode"]])
        if let code, !code.isEmpty, code != "200", code.lowercased() != "success" { return true }
        if payload["success"]?.boolValue == false || payload["ok"]?.boolValue == false { return true }
        let type = firstString(payload, paths: [["type"], ["result"]])?.lowercased() ?? ""
        return ["error", "fail", "failed", "false"].contains(type)
    }

    private func authMessage(_ payload: JSONValue, fallback: String) -> String {
        let paths = [
            ["msg"], ["message"], ["error"], ["error_description"], ["reason"], ["detail"],
            ["data"], ["data", "msg"], ["data", "message"], ["data", "error"],
            ["data", "error_description"], ["data", "reason"], ["data", "detail"],
            ["data", "tips"], ["data", "desc"],
        ]
        let message = firstString(payload, paths: paths)?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        if message.matches("验证码|captcha|verify\\s*code|code\\s*(?:error|invalid|expired)|校验码") {
            if message.matches("过期|expired|timeout|超时") { return "验证码已过期，请刷新验证码后重试" }
            if message.matches("错误|不正确|invalid|error") { return "验证码错误，请刷新验证码后重试" }
        }
        return message
    }

    private func mapAuthenticationError(_ error: Error) -> AppError {
        let message = (error as? LocalizedError)?.errorDescription ?? "认证失败"
        if message.matches("验证码|captcha|校验码") { return .invalidCaptcha(message) }
        if message.matches("密码|口令|password|账号|账户|用户名|number|credentials") {
            return .invalidCredentials(message.hasPrefix("账号或密码错误") ? message : "账号或密码错误：\(message)")
        }
        if let appError = error as? AppError { return appError }
        return .upstreamUnavailable("认证服务暂不可用")
    }

    private func hasLoginTicket(_ payload: JSONValue) -> Bool {
        loginTicket(payload).map { !$0.isEmpty } ?? false
    }

    private func loginTicket(_ payload: JSONValue) -> String? {
        firstString(payload, paths: [["data", "st"], ["data", "ticket"], ["st"], ["ticket"]])
    }

    private var userIDPaths: [[String]] {
        [
            ["data", "userId"], ["data", "users", "0", "id"], ["data", "user", "id"],
            ["userId"], ["users", "0", "id"], ["user", "id"],
        ]
    }

    private func userName(from payload: JSONValue) -> String? {
        firstString(payload, paths: [["username"], ["userName"], ["number"], ["account"], ["data", "username"], ["data", "number"]])
    }

    private func userType(from payload: JSONValue) -> String? {
        firstString(payload, paths: [["userType"], ["type"], ["data", "userType"], ["data", "type"]])
    }

    private func firstString(_ root: JSONValue, paths: [[String]]) -> String? {
        for path in paths {
            if let value = firstValue(root, path: path)?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private func firstValue(_ root: JSONValue, path: [String]) -> JSONValue? {
        var value: JSONValue? = root
        for component in path {
            if let index = Int(component), let array = value?.arrayValue, array.indices.contains(index) {
                value = array[index]
            } else {
                value = value?[component]
            }
        }
        return value
    }

    private func flattenPortalItems(_ root: JSONValue) -> [[String: JSONValue]] {
        var output: [[String: JSONValue]] = []
        func visit(_ value: JSONValue) {
            if let items = value.arrayValue {
                for item in items { visit(item) }
                return
            }
            if let object = value.objectValue {
                output.append(object)
                for key in ["data", "groups", "children", "resources", "items", "list"] {
                    if let child = object[key] { visit(child) }
                }
            }
        }
        visit(root)
        return output
    }

    private func normalizePhone(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        return digits.count == 11 && digits.first == "1" ? digits : ""
    }

    private func encodeJSON(_ value: [String: String]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: value, options: [])
        } catch {
            throw AppError.invalidResponse("无法编码认证请求")
        }
    }

    private func makeURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            throw AppError.validation("请求地址无效")
        }
        return url
    }

    private func saveCredentials(_ value: SavedCredentials) throws {
        do {
            try keychain.write(JSONEncoder().encode(value), account: Self.credentialsAccount)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storageFailure("保存账号密码失败")
        }
    }

    private func persistSession() throws {
        guard let currentUser else { return }
        let value = PersistedSession(
            version: 1,
            savedAt: Date(),
            cookies: cookieJar.persistedCookies,
            user: currentUser,
            webvpn: webvpn
        )
        do {
            try keychain.write(JSONEncoder().encode(value), account: Self.sessionAccount)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storageFailure("保存登录状态失败")
        }
    }

    /// Best-effort persistence that never throws but logs the failure so a
    /// broken session save no longer vanishes silently.
    private func persistSessionQuietly() {
        do {
            try persistSession()
        } catch {
            Log.error(.storage, LogMessage("保存登录状态失败：\(error.localizedDescription)"))
        }
    }

    private func deleteKeychainQuietly(_ account: String, label: String) {
        do {
            try keychain.delete(account)
        } catch {
            Log.error(.storage, LogMessage("删除\(label)失败：\(error.localizedDescription)"))
        }
    }

    private func checkGeneration(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw AppError.requestCancelled }
    }

    private func clearInMemorySession() {
        generation = UUID()
        cookieJar.clear()
        currentUser = nil
        webvpn = WebVPNState()
        currentCaptchaUUID = ""
        currentWechatState = nil
        smsPhone = ""
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
