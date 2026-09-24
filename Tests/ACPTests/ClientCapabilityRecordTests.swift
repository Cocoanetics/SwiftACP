@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// What `--no-fs` / `--no-terminal` leave on the record. The restriction has to outlive
/// the ephemeral `session/new`, because the daemon reconnects for every later turn and
/// would otherwise advertise the defaults again (issue #28).
struct ClientCapabilityRecordTests {
    /// The restriction has to outlive the ephemeral `session/new`: the daemon reconnects
    /// for every later turn, and would otherwise advertise the defaults again.
    @Test func restrictionsArePersistedAndRestored() {
        let restricted = ClientCapabilities(
            fs: FileSystemCapability(readTextFile: false, writeTextFile: false), terminal: false)
        let persisted = try? #require(restricted.persistedIfRestricted)

        #expect(persisted?.readTextFile == false)
        #expect(persisted?.writeTextFile == false)
        #expect(persisted?.advertised.fs.readTextFile == false)
        #expect(persisted?.advertised.fs.writeTextFile == false)
    }

    /// An unrestricted session writes no `client_capabilities` at all, so the record
    /// keeps the shape npm acpx gives it.
    @Test func anUnrestrictedSessionPersistsNothing() {
        #expect(ClientCapabilities.acpx.persistedIfRestricted == nil)
    }

    /// `--no-terminal` alone is a restriction now that terminals are advertised (#82):
    /// a reconnect must not offer them again.
    @Test func withholdingTerminalsIsPersisted() throws {
        var noTerminal = ClientCapabilities.acpx
        noTerminal.terminal = false
        let persisted = try #require(noTerminal.persistedIfRestricted)

        #expect(!persisted.advertised.terminal)
        #expect(persisted.advertised.fs.readTextFile && persisted.advertised.fs.writeTextFile)
    }

    /// Withholding only writes is a real state, not a rounding of "no fs".
    @Test func aPartialRestrictionRoundTrips() throws {
        let readOnly = ClientCapabilities(
            fs: FileSystemCapability(readTextFile: true, writeTextFile: false), terminal: false)
        let persisted = try #require(readOnly.persistedIfRestricted)

        #expect(persisted.advertised.fs.readTextFile)
        #expect(!persisted.advertised.fs.writeTextFile)
    }
}
