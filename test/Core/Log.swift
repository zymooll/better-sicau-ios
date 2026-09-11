import Foundation
import OSLog

// MARK: - 级别与类别

enum LogLevel: Int, CaseIterable, Codable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case error = 3
    case fault = 4

    var title: String {
        switch self {
        case .debug: return "调试"
        case .info: return "信息"
        case .notice: return "注意"
        case .error: return "错误"
        case .fault: return "严重"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}

enum LogCategory: String, CaseIterable, Codable, Sendable {
    case network
    case auth
    case academic
    case session
    case storage
    case ui
    case general
}

// MARK: - 消息模板与脱敏

/// A log message with placeholder-based redaction. Sensitive values (student
/// IDs, phone numbers, real names) go into `sensitive` keyed by their
/// placeholder so the redacted rendering can replace them with `<redacted>`.
///
/// NEVER put passwords, cookie values or captcha texts into `sensitive` —
/// log their presence indirectly (counts, domains, status) instead. Nothing
/// in `sensitive` ever reaches OSLog.
struct LogMessage: Sendable {
    var template: String
    var sensitive: [String: String]

    init(_ template: String, sensitive: [String: String] = [:]) {
        self.template = template
        self.sensitive = sensitive
    }

    func text(redacted: Bool) -> String {
        var output = template
        // Longest placeholder first so "{name}" never partially matches "{nameFull}".
        for (key, value) in sensitive.sorted(by: { $0.key.count > $1.key.count }) {
            output = output.replacingOccurrences(of: "{\(key)}", with: redacted ? "<redacted>" : value)
        }
        return output
    }
}

// MARK: - 条目与内存环形缓冲

struct LogEntry: Identifiable, Sendable, Codable {
    var id: UUID
    var timestamp: Date
    var level: LogLevel
    var category: LogCategory
    /// Placeholder template; contains no sensitive values by construction.
    var template: String
    /// Placeholder → plaintext value. Only used by full exports.
    var sensitive: [String: String]
    var source: String

    var redactedText: String { text(redacted: true) }
    var fullText: String { text(redacted: false) }

    func text(redacted: Bool) -> String {
        LogMessage(template, sensitive: sensitive).text(redacted: redacted)
    }
}

/// In-memory ring buffer backing the in-app log viewer. The newest entries
/// are kept up to `capacity`; OSLog remains the system-side persistence
/// layer (including after crashes), so no on-disk log file is maintained.
actor LogStore {
    private var entries: [LogEntry] = []
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Returns matching entries newest-first. \`levels\` nil means all levels.
    func snapshot(levels: Set<LogLevel>? = nil, category: LogCategory? = nil) -> [LogEntry] {
        entries
            .filter { entry in
                (levels.map { $0.contains(entry.level) } ?? true)
                    && (category.map { entry.category == $0 } ?? true)
            }
            .reversed()
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    func export(includeSensitive: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries.map { entry in
            let text = includeSensitive ? entry.fullText : entry.redactedText
            return "[\(formatter.string(from: entry.timestamp))] [\(entry.level.title)] [\(entry.category.rawValue)] \(text) @\(entry.source)"
        }.joined(separator: "\n")
    }
}

// MARK: - 静态入口（OSLog + 内存缓冲）

/// The single logging facade. Every call writes the REDACTED text to OSLog
/// (subsystem "cn.better.sicau") and appends a structured entry to the
/// in-memory \`LogStore\` for the in-app viewer. Logging never throws and
/// never blocks business logic.
enum Log {
    static let store = LogStore()
    static let subsystem = "cn.better.sicau"

    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map { category in
            (category, Logger(subsystem: subsystem, category: category.rawValue))
        }
    )

    static func debug(_ category: LogCategory, _ message: LogMessage, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        record(.debug, category, message, file: file, line: line)
        #endif
    }

    static func info(_ category: LogCategory, _ message: LogMessage, file: String = #fileID, line: Int = #line) {
        record(.info, category, message, file: file, line: line)
    }

    static func notice(_ category: LogCategory, _ message: LogMessage, file: String = #fileID, line: Int = #line) {
        record(.notice, category, message, file: file, line: line)
    }

    static func error(_ category: LogCategory, _ message: LogMessage, file: String = #fileID, line: Int = #line) {
        record(.error, category, message, file: file, line: line)
    }

    static func fault(_ category: LogCategory, _ message: LogMessage, file: String = #fileID, line: Int = #line) {
        record(.fault, category, message, file: file, line: line)
    }

    private static func record(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: LogMessage,
        file: String,
        line: Int
    ) {
        let source = "\((file as NSString).lastPathComponent):\(line)"
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            category: category,
            template: message.template,
            sensitive: message.sensitive,
            source: source
        )
        Task { await store.append(entry) }
        // OSLog only ever sees the redacted rendering.
        loggers[category]?.log(level: level.osLogType, "\(entry.redactedText, privacy: .public) @\(source, privacy: .public)")
    }
}
