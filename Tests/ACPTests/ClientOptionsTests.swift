@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// What acpxd offers an agent it connects, built from a prompt's or a control's `--no-fs` and
/// `--no-terminal` as acpx builds its client from them (#246).
struct ClientOptionsTests {
    @Test func noFsWithholdsBothFilesystemMethods() {
        let capabilities = ClientCapabilities.acpx(ClientOptions(fs: false))
        #expect(!capabilities.fs.readTextFile && !capabilities.fs.writeTextFile)
        #expect(capabilities.terminal == ClientCapabilities.acpx.terminal)
    }

    @Test func noTerminalWithholdsTheTerminal() {
        let capabilities = ClientCapabilities.acpx(ClientOptions(terminal: false))
        #expect(!capabilities.terminal)
        #expect(capabilities.fs.readTextFile && capabilities.fs.writeTextFile)
    }

    /// Nothing asked for, or `true`, is acpx's own client.
    @Test func nothingWithheldIsAcpxsOwn() {
        for options in [ClientOptions(), ClientOptions(fs: true, terminal: true, authPolicy: "fail")] {
            let capabilities = ClientCapabilities.acpx(options)
            #expect(capabilities.fs.readTextFile == ClientCapabilities.acpx.fs.readTextFile)
            #expect(capabilities.fs.writeTextFile == ClientCapabilities.acpx.fs.writeTextFile)
            #expect(capabilities.terminal == ClientCapabilities.acpx.terminal)
        }
    }
}
