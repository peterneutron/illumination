import Foundation

enum AppPolicyScope: Int {
    case everywhere = 0
    case apps = 1

    var displayName: String {
        switch self {
        case .everywhere: return "Everywhere"
        case .apps: return "Apps"
        }
    }
}

struct AppPolicyDecision: Equatable {
    let isBlocked: Bool
    let result: String
}

enum AppPolicy {
    static func decide(scope: AppPolicyScope, frontmostDenylisted: Bool) -> AppPolicyDecision {
        switch scope {
        case .everywhere:
            return AppPolicyDecision(isBlocked: false, result: "allowed")
        case .apps:
            return frontmostDenylisted
                ? AppPolicyDecision(isBlocked: true, result: "blocked")
                : AppPolicyDecision(isBlocked: false, result: "allowed")
        }
    }
}
