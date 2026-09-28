import Foundation
import SwiftACP

extension ClientCapabilities {
    /// acpx's client with its `fs` option: `false` (`--no-fs`) withholds both filesystem
    /// methods; anything else leaves acpx's own.
    public static func acpx(fs: Bool?) -> ClientCapabilities {
        acpx(ClientOptions(fs: fs))
    }

    /// acpx's client built with `client`'s `fs` and `terminal`: `false` (`--no-fs`,
    /// `--no-terminal`) withholds the filesystem methods or the terminal; anything else leaves
    /// acpx's own.
    public static func acpx(_ client: ClientOptions) -> ClientCapabilities {
        var capabilities = ClientCapabilities.acpx
        if client.fs == false { capabilities.fs = FileSystemCapability(readTextFile: false, writeTextFile: false) }
        if client.terminal == false { capabilities.terminal = false }
        return capabilities
    }
}
