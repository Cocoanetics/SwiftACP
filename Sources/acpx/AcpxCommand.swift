import ACPXCore
import ArgumentParser
import Foundation

/// `acpx` — the headless CLI, a faithful clone of openclaw/acpx 0.11.0.
///
/// acpx uses a commander-style positional model (`acpx [globals] <agent> <subcommand> …`)
/// where the leading token is a dynamic agent name — something ArgumentParser can't
/// express directly. So every argument is captured verbatim and handed to ``Router``,
/// which re-scans argv per command. This type only provides the entry point and maps
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
        let code = dispatch(arguments)
        if code != ExitCodes.success { throw ExitCode(code) }
    }
}

/// Dispatch `arguments` through the router, mapping thrown errors to acpx exit codes
/// (printed to stderr exactly as the CLI does).
private func dispatch(_ arguments: [String]) -> Int32 {
    do {
        return try Router.dispatch(arguments)
    } catch let error as UsageError {
        // commander prints the message, a blank line and the full help screen,
        // all to stderr, and exits 1 — not `EXIT_CODES.USAGE`, which acpx keeps
        // for runtime errors carrying a `USAGE` output code.
        Console.errLine("error: \(error.message)")
        if let usage = error.usage { Console.err("\n" + usage) }
        guard error.scope == .root else { return ExitCodes.error }
        // A global option is rejected twice upstream: commander writes the
        // message and the root help, then *throws* instead of exiting, so acpx's
        // own top-level handler prints the same message again and exits USAGE.
        Console.errLine("error: \(error.message)")
        return ExitCodes.usage
    } catch {
        // Everything else — a broken config, a missing session, a command's own
        // failure — is reported as acpx's top-level handler reports it, in the output
        // format the invocation asked for.
        return TopLevelFailure.report(error, arguments: arguments)
    }
}
