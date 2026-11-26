import Foundation
import os

/// 开发时看日志用：`log stream --predicate 'subsystem == "com.omniomo.eyeline"'`。
enum Log {
    private static let logger = Logger(subsystem: "com.omniomo.eyeline", category: "app")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
