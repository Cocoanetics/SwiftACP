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
        // acpx's `isOutputAlreadyEmitted`: the output shows it already; only the exit
        // code is left to give.
        if let shown = error as? FailureAlreadyShown {
            return shown.outputCode.map(exitCode(forOutputCode:)) ?? Failure(shown.underlying).processExitCode
        }
        let failure = Failure(error)
        let (outputCode, detailCode, message) = (failure.outputCode, failure.detailCode, failure.message)
        switch requestedFormat(arguments) {
        case "json":
            // An agent's error keeps its own code and message, its data merged in.
            out(JSONErrorLine.make(
                outputCode: outputCode, detailCode: detailCode, origin: failure.origin, message: message,
                sessionId: "unknown", acp: failure.acp) + "\n")
        case "quiet":
            // acpx's quiet formatter: the agent's `data.details`, when it gave some.
            let qualifier = detailCode.map { "\(outputCode) \($0)" } ?? outputCode
            let oneLine = (failure.acp?.details ?? message).replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            err("[acpx] error: \(qualifier) \(oneLine)")
        default:
            err(message)
            for hint in remediationHints(
                code: outputCode, origin: failure.origin, detailCode: detailCode, message: message, acp: failure.acp) {
                err(hint)
            }
        }
        return failure.processExitCode
    }

    /// A failure as acpx's `normalizeOutputError` sees it at the top level.
    private struct Failure {
        var outputCode = "RUNTIME"
        var detailCode: String?
        var origin = "cli"
        var message: String
        /// The agent's error the failure is, when it is one (acpx's `extractAcpError`).
        var acp: AcpErrorPayload?
        var commandExitCode: Int32?

        init(_ error: Error) {
            // `formatErrorMessage`: an agent's error by its message.
            message = TurnFailure.message(of: error)
            acp = TurnFailure.payload(of: error)
            switch error {
            case let noSession as NoSessionError:
                outputCode = "NO_SESSION"
                message = noSession.message
            case let cliError as CLIError:
                message = cliError.message
                commandExitCode = cliError.code
                outputCode = outputCodeForExitCode(cliError.code)
            case let invalid as InvalidArgumentError:
                outputCode = "USAGE"
                message = invalid.message
            case let meta as OutputErrorMeta:
                outputCode = meta.outputCode ?? outputCode
                detailCode = meta.detailCode
                origin = meta.origin ?? origin
            default:
                break
            }
            // `resolveOutputErrorCode`: a runtime failure saying the session is gone.
            if outputCode == "RUNTIME", ReconnectFallback.isResourceNotFound(error) { outputCode = "NO_SESSION" }
            // `resolveDetailCode`: an agent's error saying it needs credentials.
            if detailCode == nil, acp?.saysAuthRequired == true { detailCode = "AUTH_REQUIRED" }
        }

        var processExitCode: Int32 { commandExitCode ?? exitCode(forOutputCode: outputCode) }
    }

    /// A parse failure as commander and acpx report it. commander prints `error:
    /// <message>` and the failing command's help to stderr — nothing under
    /// `--json-strict`. A subcommand's failure then exits 1. The root's also reaches
    /// acpx's handler, which reports commander's message again in the requested format,
    /// as `USAGE`, and exits 2.
    static func reportParseFailure(
        _ error: UsageError, arguments: [String],
        out: (String) -> Void = { Console.out($0) }, err: (String) -> Void = { Console.errLine($0) },
        errText: (String) -> Void = { Console.err($0) }
    ) -> Int32 {
        if !LeadingFlags.jsonStrict(arguments) {
            err("error: \(error.message)")
            if let usage = error.usage { errText("\n" + usage) }
        }
        guard error.scope == .root else { return ExitCodes.error }
        return report(InvalidArgumentError("error: \(error.message)"), arguments: arguments, out: out, err: err)
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

/// acpx's `outputAlreadyEmitted`: a failure the output already shows — the agent's
/// error response in the `--format json` stream. The top level prints nothing more
/// for it, and exits as `underlying` says.
struct FailureAlreadyShown: Error {
    let underlying: Error
    /// The output code the exit code follows, when the failure was already classified.
    var outputCode: String?
}
