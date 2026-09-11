import Foundation

enum AppError: LocalizedError, Equatable, Sendable {
    case authenticationExpired
    case invalidCaptcha(String)
    case invalidCredentials(String)
    case requestTimedOut
    case requestCancelled
    case invalidResponse(String)
    case upstreamUnavailable(String)
    case unsupported(String)
    case storageFailure(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .authenticationExpired:
            return "登录状态已失效，请重新登录"
        case .invalidCaptcha(let message), .invalidCredentials(let message),
             .invalidResponse(let message), .upstreamUnavailable(let message),
             .unsupported(let message), .storageFailure(let message),
             .validation(let message):
            return message
        case .requestTimedOut:
            return "请求超时，请检查网络后重试"
        case .requestCancelled:
            return "请求已取消"
        }
    }
}
