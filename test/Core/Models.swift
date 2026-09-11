import Foundation

struct UserProfile: Codable, Equatable, Sendable {
    var username: String
    var userType: String = ""
    var loggedInAt: Date = .now
}

struct CaptchaChallenge: Codable, Equatable, Sendable {
    var uuid: String
    var imageData: Data
}

struct CaptchaRecognition: Equatable, Sendable {
    var text: String
    var confidence: Double
}

enum WechatLoginStatus: String, Codable, Sendable {
    case pending
    case scanned
    case bindRequired
    case success
    case expired
}

struct WechatLoginState: Codable, Equatable, Sendable {
    var state: String
    var url: URL?
    var status: WechatLoginStatus
    var message: String
    var expiresAt: Date
    var user: UserProfile?
}

struct SavedCredentials: Codable, Equatable, Sendable {
    var username: String
    var password: String
}

struct GradeItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { RecordIdentity.make([term, courseID, course, name, teacher, className, source, index, score]) }
    var index = ""
    var courseID = ""
    var name = ""
    var className = ""
    var year = ""
    var course = ""
    var teacher = ""
    var courseType = ""
    var credit = ""
    var term = ""
    var score = ""
    var gradePoint = ""
    var source = ""
    var valid = ""
    var campus = ""
    var note = ""
    var raw: [String: String] = [:]
}

struct RankingMetric: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(label)|\(value)" }
    var label: String
    var value: String
}

struct GradeRanking: Codable, Equatable, Sendable {
    var title = ""
    var summary = ""
    var metrics: [RankingMetric] = []
    var rawText = ""
}

struct GradeRankings: Codable, Equatable, Sendable {
    var initialRequired: GradeRanking?
    var all: GradeRanking?
}

struct GradeSnapshot: Codable, Equatable, Sendable {
    var grades: [GradeItem]
    var rankings: GradeRankings
    var warnings: [String] = []
}

struct ExamItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { RecordIdentity.make([term, course, time, location, seat, type, teacher, note]) }
    var course = ""
    var time = ""
    var location = ""
    var seat = ""
    var teacher = ""
    var type = ""
    var term = ""
    var note = ""
    var raw: [String: String] = [:]
}

struct ScheduleItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { RecordIdentity.make([term, course, String(dayOfWeek ?? 0), dayLabel, String(sectionStart ?? 0), String(sectionEnd ?? 0), sectionLabel, teacher, location, weeks, note]) }
    var course = ""
    var dayOfWeek: Int?
    var dayLabel = ""
    var sectionStart: Int?
    var sectionEnd: Int?
    var sectionLabel = ""
    var teacher = ""
    var location = ""
    var weeks = ""
    var term = ""
    var note = ""
    var raw: [String: String] = [:]
}

struct TermSettings: Codable, Equatable, Sendable {
    var currentTerm: String
    var startDates: [String: String]
}

struct QueryProgress: Equatable, Sendable {
    enum Phase: Sendable {
        case idle
        case loading
        case parsing
        case done
    }

    var scope: String
    var message: String
    var step: Int
    var total: Int
    var phase: Phase
    var steps: [String] = []

    static func running(_ steps: [String], at index: Int) -> QueryProgress {
        QueryProgress(scope: "", message: steps[index], step: index + 1, total: steps.count, phase: .loading, steps: steps)
    }
}

/// Length-prefixed fields avoid collisions when upstream text contains delimiters.
enum RecordIdentity {
    static func make(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct AcademicLoadState: Equatable {
    var progress: QueryProgress?
    var error: String?
    var warnings: [String] = []
    var updatedAt: Date?
    var hasLoaded = false
}

typealias AcademicProgress = @Sendable (QueryProgress) async -> Void

extension ExamItem {
    var isResit: Bool {
        let value = (type + note).lowercased()
        return value.contains("缓") || value.contains("补") || value.contains("重修") || value.contains("resit")
    }
}

