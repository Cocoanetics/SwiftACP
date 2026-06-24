/// SwiftACP umbrella.
///
/// `import SwiftACP` re-exports both halves of the package, so a single import
/// brings the protocol + client (``ACP``) and the agent/server harness
/// (``ACPServer``). The sub-modules remain importable on their own when a
/// consumer wants only one half (e.g. a client-only host that skips the server).
@_exported import ACP
@_exported import ACPServer
