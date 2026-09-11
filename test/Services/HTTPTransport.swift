import Foundation

struct HTTPResult: Sendable {
    var status: Int
    var headers: [String: String]
    var setCookieHeaders: [String]
    var data: Data
    var text: String
    var url: URL
}

struct NetworkConfiguration: Sendable {
    var timeout: TimeInterval = 30
    var maxResponseBytes: Int = 10 * 1024 * 1024
    var maxRedirects: Int = 10
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class HTTPTransport: @unchecked Sendable {
    private let session: URLSession
    private let configuration: NetworkConfiguration

    init(
        configuration: NetworkConfiguration = NetworkConfiguration(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = NetworkConfiguration(
            timeout: max(0.1, configuration.timeout),
            maxResponseBytes: max(1, configuration.maxResponseBytes),
            maxRedirects: max(0, configuration.maxRedirects)
        )
        let copy = sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        copy.httpShouldSetCookies = false
        copy.httpCookieStorage = nil
        copy.timeoutIntervalForRequest = self.configuration.timeout
        copy.timeoutIntervalForResource = self.configuration.timeout
        copy.waitsForConnectivity = false
        self.session = URLSession(configuration: copy)
    }

    func execute(_ request: URLRequest) async throws -> HTTPResult {
        guard request.url?.scheme?.lowercased() == "https" else {
            Log.error(.network, LogMessage("拒绝非 HTTPS 上游请求"))
            throw AppError.upstreamUnavailable("上游请求必须使用 HTTPS")
        }
        var request = request
        request.timeoutInterval = configuration.timeout
        guard let requestURL = request.url else {
            Log.error(.network, LogMessage("上游请求地址无效"))
            throw AppError.validation("请求地址无效")
        }

        let startedAt = Date()
        do {
            let delegate = NoRedirectDelegate()
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.invalidResponse("上游响应不是 HTTP 响应")
            }
            let expectedLength = httpResponse.expectedContentLength
            if expectedLength > Int64(configuration.maxResponseBytes) {
                throw AppError.upstreamUnavailable("上游响应内容过大")
            }

            var body = Data()
            body.reserveCapacity(expectedLength > 0 ? min(Int(expectedLength), configuration.maxResponseBytes) : 0)
            for try await byte in bytes {
                if Task.isCancelled { throw AppError.requestCancelled }
                if body.count >= configuration.maxResponseBytes {
                    throw AppError.upstreamUnavailable("上游响应内容过大")
                }
                body.append(byte)
            }

            let headers = Self.headerMap(httpResponse)
            let setCookies = Self.setCookieValues(httpResponse)
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.info(.network, LogMessage("HTTP \(request.httpMethod ?? "GET") \(requestURL.path) → \(httpResponse.statusCode)（\(body.count) 字节，\(elapsed) ms）"))
            return HTTPResult(
                status: httpResponse.statusCode,
                headers: headers,
                setCookieHeaders: setCookies,
                data: body,
                text: Self.decode(body, contentType: headers["content-type"] ?? ""),
                url: requestURL
            )
        } catch let error as AppError {
            Log.error(.network, LogMessage("HTTP \(request.httpMethod ?? "") \(requestURL.path) 失败：\(error.errorDescription ?? "未知错误")"))
            throw error
        } catch is CancellationError {
            Log.info(.network, LogMessage("HTTP \(requestURL.path) 已取消"))
            throw AppError.requestCancelled
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                Log.info(.network, LogMessage("HTTP \(requestURL.path) 已取消"))
                throw AppError.requestCancelled
            }
            if error.code == .timedOut {
                Log.error(.network, LogMessage("HTTP \(requestURL.path) 超时（\(Int(configuration.timeout)) 秒）"))
                throw AppError.requestTimedOut
            }
            Log.error(.network, LogMessage("HTTP \(requestURL.path) 失败：\(Self.networkMessage(error))"))
            throw AppError.upstreamUnavailable(Self.networkMessage(error))
        } catch {
            if Task.isCancelled {
                Log.info(.network, LogMessage("HTTP \(requestURL.path) 已取消"))
                throw AppError.requestCancelled
            }
            Log.error(.network, LogMessage("HTTP \(requestURL.path) 失败：\(Self.networkMessage(error))"))
            throw AppError.upstreamUnavailable(Self.networkMessage(error))
        }
    }

    private static func headerMap(_ response: HTTPURLResponse) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key).lowercased()
            if let values = value as? [String] {
                map[name] = values.joined(separator: ", ")
            } else {
                map[name] = String(describing: value)
            }
        }
        return map
    }

    private static func setCookieValues(_ response: HTTPURLResponse) -> [String] {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            if let values = value as? [String] { return values }
            if let values = value as? NSArray { return values.compactMap { $0 as? String } }
            if let string = value as? String { return [string] }
            return [String(describing: value)]
        }
        return []
    }

    private static func decode(_ data: Data, contentType: String) -> String {
        let charset = contentType
            .split(separator: ";")
            .dropFirst()
            .compactMap { part -> String? in
                let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { return nil }
                return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .first

        let candidates: [String.Encoding] = [charset.flatMap(Self.encoding(for:)), .utf8, Self.gb18030Encoding, .isoLatin1].compactMap { $0 }
        for encoding in candidates {
            if let string = String(data: data, encoding: encoding) { return string }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(for name: String) -> String.Encoding? {
        switch name.lowercased().replacingOccurrences(of: "-", with: "") {
        case "utf8": return .utf8
        case "gb18030", "gbk", "gb2312", "cp936": return gb18030Encoding
        case "iso88591", "latin1": return .isoLatin1
        case "ascii", "usascii": return .ascii
        default: return nil
        }
    }

    private static var gb18030Encoding: String.Encoding? {
        #if canImport(CoreFoundation)
        let encoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        #else
        return nil
        #endif
    }

    private static func networkMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return "无法连接上游服务"
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "上游 HTTPS 连接失败"
            default:
                break
            }
        }
        return "上游网络请求失败"
    }
}
