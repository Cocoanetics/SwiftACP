import ACPXCore
import Foundation
import SwiftACP

/// acpx's `emitRequestedError`: how a failure that reaches the top level is reported,
/// in the output format the invocation asked for — one JSON-RPC error line in json
/// mode, `[acpx] error: <CODE> <message>` in quiet mode, the bare message with its
/// hints in text mode. The format comes from the leading flags, as acpx reads them
/// before (or without) a config, falling back to the config's own `format`.
enum TopLevelFailure {
    static func report(
        _ error: Error, arguments: [String],
        out: (String) -> Void = { Console.out($0) }, err: (String) -> Void = { Console.errLine($0) }
    ) -> Int32 {
        var outputCode = "RUNTIME"
        var detailCode: String?
        var message = error.localizedDescription
        var commandExitCode: Int32?
        switch error {
        case let noSession as NoSessionError:
            outputCode = "NO_SESSION"
            message = noSession.message
        case let cliError as CLIError:
            message = cliError.message
            commandExitCode = cliError.code
            outputCode = outputCodeForExitCode(cliError.code)
        case let launch as AgentLaunchError:
            detailCode = launch.detailCode
        default:
            break
        }
        // `resolveOutputErrorCode`: a runtime failure saying the session is gone.
        if outputCode == "RUNTIME", ReconnectFallback.isResourceNotFound(error) { outputCode = "NO_SESSION" }

        switch requestedFormat(arguments) {
        case "json":
            out(JSONErrorLine.make(
                outputCode: outputCode, detailCode: detailCode, origin: "cli", message: message,
                sessionId: "unknown") + "\n")
        case "quiet":
            let qualifier = detailCode.map { "\(outputCode) \($0)" } ?? outputCode
            let oneLine = message.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            err("[acpx] error: \(qualifier) \(oneLine)")
        default:
            err(message)
            for hint in remediationHints(
                code: outputCode, origin: "cli", detailCode: detailCode, message: message, acpCode: nil) {
                err(hint)
            }
        }
        return commandExitCode ?? exitCode(forOutputCode: outputCode)
    }

    /// The format acpx reports a top-level failure in: what the arguments ask for
    /// (``LeadingFlags/requestedFormat(_:fallback:)``), else the `format` of the config
    /// acpx loads at start-up, else text when that config does not load.
    static func requestedFormat(_ arguments: [String]) -> String {
        LeadingFlags.requestedFormat(arguments) {
            let config = try? ConfigLoader.load(
                cwd: LeadingFlags.initialCwd(arguments, base: physicalCWD()),
                mcpConfigPath: LeadingFlags.mcpConfigPath(arguments))
            return config?.format ?? "text"
        }
    }

    /// The output code a command's exit code stands for (the inverse of
    /// ``exitCode(forOutputCode:)``).
    static func outputCodeForExitCode(_ code: Int32) -> String {
        switch code {
        case ExitCodes.usage: return "USAGE"
        case ExitCodes.timeout: return "TIMEOUT"
        case ExitCodes.noSession: return "NO_SESSION"
        case ExitCodes.permissionDenied: return "PERMISSION_DENIED"
        default: return "RUNTIME"
        }
    }
}
