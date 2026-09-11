import Foundation

struct StoredCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var hostOnly: Bool
    var secure: Bool
    var httpOnly: Bool
    var expiresAt: Date?
    var createdAt: Date
}

struct CookieJar: Codable, Equatable, Sendable {
    private var cookies: [String: StoredCookie] = [:]

    init(cookies: [StoredCookie] = [], now: Date = Date()) {
        for cookie in cookies where cookie.expiresAt.map({ $0 > now }) ?? true {
            self.cookies[Self.key(for: cookie)] = cookie
        }
    }

    var persistedCookies: [StoredCookie] {
        persistedCookies(at: Date())
    }

    /// Same as `persistedCookies` but with an injectable clock for tests.
    func persistedCookies(at now: Date) -> [StoredCookie] {
        cookies.values
            .filter { $0.expiresAt.map { $0 > now } ?? true }
            .sorted { lhs, rhs in
                if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
                if lhs.path != rhs.path { return lhs.path < rhs.path }
                return lhs.name < rhs.name
            }
    }

    mutating func set(from headers: [String], requestURL: URL, now: Date = Date()) {
        for combinedHeader in headers {
            for header in Self.splitCombinedSetCookieHeader(combinedHeader) {
                set(header, requestURL: requestURL, now: now)
            }
        }
        removeExpired(now: now)
    }

    mutating func header(for url: URL, now: Date = Date()) -> String {
        removeExpired(now: now)
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "" }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"

        return cookies.values
            .filter { cookie in
                if cookie.secure && !isSecure { return false }
                let domainMatches = cookie.hostOnly
                    ? host == cookie.domain
                    : Self.domainMatches(host: host, domain: cookie.domain)
                return domainMatches && Self.pathMatches(requestPath: requestPath, cookiePath: cookie.path)
            }
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
                return lhs.createdAt < rhs.createdAt
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    mutating func clear() {
        cookies.removeAll(keepingCapacity: false)
    }

    private mutating func set(_ header: String, requestURL: URL, now: Date) {
        var parts = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return }

        let pair = parts.removeFirst()
        guard let separator = pair.firstIndex(of: "=") else { return }
        let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var attributes: [String: String] = [:]
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let index = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
                attributes[key] = value
            } else {
                attributes[trimmed.lowercased()] = ""
            }
        }

        guard let requestHost = requestURL.host?.lowercased(), !requestHost.isEmpty else { return }
        let domainAttribute = attributes["domain"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased() ?? ""
        guard domainAttribute.isEmpty || Self.domainMatches(host: requestHost, domain: domainAttribute) else {
            return
        }

        let domain = domainAttribute.isEmpty ? requestHost : domainAttribute
        let requestPath = requestURL.path.isEmpty ? "/" : requestURL.path
        let proposedPath = attributes["path"] ?? ""
        let path = proposedPath.hasPrefix("/") ? proposedPath : Self.defaultPath(for: requestPath)
        let key = Self.key(domain: domain, path: path, name: name)

        let maxAge = attributes["max-age"].flatMap(TimeInterval.init)
        let explicitExpiry = attributes["expires"].flatMap(Self.parseCookieDate)
        if value.isEmpty || maxAge.map({ $0 <= 0 }) == true || explicitExpiry.map({ $0 <= now }) == true {
            cookies.removeValue(forKey: key)
            return
        }

        let expiresAt = maxAge.map { now.addingTimeInterval($0) } ?? explicitExpiry
        let cookie = StoredCookie(
            name: name,
            value: value,
            domain: domain,
            path: path,
            hostOnly: domainAttribute.isEmpty,
            secure: attributes.keys.contains("secure"),
            httpOnly: attributes.keys.contains("httponly"),
            expiresAt: expiresAt,
            createdAt: now
        )
        cookies[key] = cookie
    }

    private mutating func removeExpired(now: Date) {
        cookies = cookies.filter { _, cookie in
            cookie.expiresAt.map { $0 > now } ?? true
        }
    }

    private static func key(for cookie: StoredCookie) -> String {
        key(domain: cookie.domain, path: cookie.path, name: cookie.name)
    }

    private static func key(domain: String, path: String, name: String) -> String {
        "\(domain)\t\(path)\t\(name)"
    }

    private static func defaultPath(for requestPath: String) -> String {
        guard requestPath.hasPrefix("/"), requestPath != "/",
              let lastSlash = requestPath.lastIndex(of: "/"), lastSlash != requestPath.startIndex else {
            return "/"
        }
        return String(requestPath[..<lastSlash])
    }

    static func domainMatches(host: String, domain: String) -> Bool {
        let normalizedHost = host.lowercased()
        let normalizedDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !normalizedHost.isEmpty, !normalizedDomain.isEmpty else { return false }
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix(".\(normalizedDomain)")
    }

    static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        let request = requestPath.isEmpty ? "/" : requestPath
        let cookie = cookiePath.isEmpty ? "/" : cookiePath
        if request == cookie { return true }
        return request.hasPrefix(cookie.hasSuffix("/") ? cookie : "\(cookie)/")
    }

    static func splitCombinedSetCookieHeader(_ header: String) -> [String] {
        var result: [String] = []
        var start = header.startIndex
        var index = header.startIndex

        while index < header.endIndex {
            guard header[index] == "," else {
                index = header.index(after: index)
                continue
            }

            var candidate = header.index(after: index)
            while candidate < header.endIndex, header[candidate].isWhitespace {
                candidate = header.index(after: candidate)
            }
            let tokenStart = candidate
            while candidate < header.endIndex, Self.isCookieTokenCharacter(header[candidate]) {
                candidate = header.index(after: candidate)
            }
            if candidate > tokenStart, candidate < header.endIndex, header[candidate] == "=" {
                let item = header[start..<index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { result.append(item) }
                start = header.index(after: index)
            }
            index = header.index(after: index)
        }

        let tail = header[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func isCookieTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character)
    }

    private static func parseCookieDate(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
