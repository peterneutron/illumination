import Foundation
import OSLog

enum RuntimeIssue: String {
    case metalDeviceUnavailable
    case metalCommandQueueUnavailable
    case overlayCreationFailed
    case tilePanelUnavailable
    case unsupportedCoderInit
}

final class RuntimeDiagnostics {
    static let shared = RuntimeDiagnostics()

    private let logger = Logger(subsystem: "com.neutronstar.Illumination", category: "runtime")
    private(set) var lastIssue: String?

    private init() {}

    func report(_ issue: RuntimeIssue, details: String? = nil) {
        if let details {
            logger.error("\(issue.rawValue, privacy: .public): \(details, privacy: .public)")
            lastIssue = "\(issue.rawValue): \(details)"
        } else {
            logger.error("\(issue.rawValue, privacy: .public)")
            lastIssue = issue.rawValue
        }
    }
}
