@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// `config init` as acpx's `initGlobalConfigFile` makes the global config (#251).
@Suite(.serialized) struct ConfigInitTests {
    /// The directory and the file are the owner's alone — the file can hold `auth` credentials —
    /// and a file there already is kept as it is, reported as not created.
    @Test func theConfigIsOwnerOnlyAndNeverOverwritten() async throws {
        try await withIsolatedStore {
            try? FileManager.default.removeItem(at: ACPXPaths.baseDir)
            let first = Self.run(["--format", "json", "config", "init"])
            #expect(first.code == 0)
            #expect(first.out.contains(#""created":true"#))
            #expect(try Self.mode(ACPXPaths.baseDir.path) == 0o700)
            #expect(try Self.mode(ACPXPaths.globalConfigPath.path) == 0o600)

            try Data(#"{"defaultAgent": "mine"}"#.utf8).write(to: ACPXPaths.globalConfigPath)
            let again = Self.run(["--format", "json", "config", "init"])
            #expect(again.code == 0)
            #expect(again.out.contains(#""created":false"#))
            #expect(try String(contentsOf: ACPXPaths.globalConfigPath, encoding: .utf8) == #"{"defaultAgent": "mine"}"#)
        }
    }

    static func run(_ arguments: [String]) -> (code: Int32, out: String) {
        let capture = Console.Capture()
        let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
        return (code, capture.out)
    }

    static func mode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0) & 0o777
    }
}
