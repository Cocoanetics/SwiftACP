import ACPXCore
import ArgumentParser
import Foundation

/// `acpx` — the headless CLI, a faithful clone of openclaw/acpx 0.19.1.
///
/// acpx parses with commander (`acpx [globals] <agent> <subcommand> …`), where the
/// leading token is a dynamic agent name — something ArgumentParser can't express
/// directly. So every argument is captured verbatim and handed to ``Router``, which
/// parses it as commander does (``Commander``). This type only provides the entry point and maps
/// the router's result to a process exit code. It's a synchronous `ParsableCommand`
/// because the router is synchronous (it bridges async via `runBlocking`).
@main
struct AcpxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acpx",
        abstract: "Remote-control Claude Code & Codex coding agents via the Agent Client Protocol."
    )

    @Argument(parsing: .captureForPassthrough, help: "Agent name, subcommand, and its arguments.")
    var arguments: [String] = []

    func run() throws {
        bootstrapACPXLogging()
        let code = runCommandLine(arguments)
        if code != ExitCodes.success { throw ExitCode(code) }
    }
}

/// Dispatch `arguments` through the router, mapping thrown errors to acpx exit codes
/// (printed exactly as the CLI does).
func runCommandLine(_ arguments: [String]) -> Int32 {
    do {
        return try Router.dispatch(arguments)
    } catch let error as UsageError {
        return TopLevelFailure.reportParseFailure(error, arguments: arguments)
    } catch {
        // Everything else — a broken config, a missing session, a command's own
        // failure — is reported as acpx's top-level handler reports it, in the output
        // format the invocation asked for.
        return TopLevelFailure.report(error, arguments: arguments)
    }
}
