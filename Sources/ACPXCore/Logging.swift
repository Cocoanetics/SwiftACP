import Foundation
import Logging

/// Installs the process's swift-log backend. On Apple platforms this bridges
/// `Logging` to OSLog (Console.app / `log stream`), keeping the CLI's stdout/
/// stderr clean for command output. Call once at process start.
///
/// Set `ENABLE_DEBUG_OUTPUT=1` to lower the level to `.trace`.
public func bootstrapACPXLogging() {
    let level: Logging.Logger.Level =
        ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" ? .trace : .info
    #if canImport(OSLog)
        LoggingSystem.bootstrap { label in
            var handler = OSLogHandler(label: label)
            handler.logLevel = level
            return handler
        }
    #else
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    #endif
}

#if canImport(OSLog)
    @preconcurrency import OSLog

    /// A swift-log backend routing messages to Apple's unified logging system.
    /// Subsystem = first three dot-segments of the label (e.g. `com.cocoanetics.SwiftMCP`);
    /// category = the fourth segment (e.g. `TCPBonjourTransport`).
    public struct OSLogHandler: LogHandler {
        public let label: String
        private let osLog: OSLog

        public var metadata: Logging.Logger.Metadata = [:]
        public var metadataProvider: Logging.Logger.MetadataProvider?
        public var logLevel: Logging.Logger.Level = .info

        public init(label: String) {
            self.label = label
            let parts = label.split(separator: ".", maxSplits: 4)
            let subsystem = parts.count >= 3 ? parts[0 ... 2].joined(separator: ".") : label
            let category = parts.count >= 4 ? String(parts[3]) : "general"
            self.osLog = OSLog(subsystem: subsystem, category: category)
        }

        public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        public func log(event: LogEvent) {
            let type: OSLogType =
                switch event.level {
                case .trace, .debug: .debug
                case .info, .notice: .info
                case .warning: .default
                case .error: .error
                case .critical: .fault
                }
            os_log("%{public}@", log: osLog, type: type, event.message.description)
        }
    }
#endif
