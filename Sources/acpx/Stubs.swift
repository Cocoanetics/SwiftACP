import ACPXCore
import Foundation

/// `flow run` executes TypeScript/JavaScript flow modules in the upstream acpx,
/// which a native Swift port cannot evaluate. Reported explicitly.
enum FlowCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        throw CLIError(
            "flow: not supported in the Swift port (flows are JavaScript modules executed by the Node-based acpx)")
    }
}
