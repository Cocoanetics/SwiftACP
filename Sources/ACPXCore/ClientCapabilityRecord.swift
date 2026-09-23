import Foundation
import SwiftACP

// Bridging the advertised `ClientCapabilities` and the record's persisted form, so a
// session created under `--no-fs` / `--no-terminal` keeps those restrictions across
// reconnects instead of quietly regaining the methods on the next connection.

extension SessionAcpxState.PersistedCapabilities {
    public init(_ capabilities: ClientCapabilities) {
        self.init(
            readTextFile: capabilities.fs.readTextFile,
            writeTextFile: capabilities.fs.writeTextFile,
            terminal: capabilities.terminal)
    }

    /// What to advertise on the next connection.
    public var advertised: ClientCapabilities {
        ClientCapabilities(
            fs: FileSystemCapability(readTextFile: readTextFile, writeTextFile: writeTextFile),
            terminal: terminal)
    }
}

extension ClientCapabilities {
    /// The persisted form, or `nil` when nothing was withheld — an unrestricted session
    /// writes no `client_capabilities` at all, keeping the record as npm acpx shapes it.
    public var persistedIfRestricted: SessionAcpxState.PersistedCapabilities? {
        let defaults = ClientCapabilities.headlessController
        guard fs.readTextFile != defaults.fs.readTextFile
            || fs.writeTextFile != defaults.fs.writeTextFile
            || terminal != defaults.terminal
        else { return nil }
        return SessionAcpxState.PersistedCapabilities(self)
    }
}
