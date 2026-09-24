@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
import Testing

/// The CLI's JSON documents are acpx's: its keys in its order, printed as
/// `JSON.stringify` prints them (#66). The expected text was printed by npm acpx 0.19.1
/// for the same config, with its paths shown as `<home>` and `<cwd>`.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct JSONOutputTests {
    private static let expectedText = """
        {
          "defaultAgent": "zeta",
          "defaultPermissions": "deny-all",
          "nonInteractivePermissions": "deny",
          "authPolicy": "skip",
          "ttl": 0.5,
          "timeout": 90.5,
          "queueMaxDepth": 4,
          "format": "text",
          "agents": {
            "zeta": {
              "command": "z"
            },
            "alpha": {
              "command": "a b"
            }
          },
          "authMethods": [
            "a",
            "b"
          ],
          "disableExec": true,
          "paths": {
            "global": "<home>/.acpx/config.json",
            "project": "<cwd>/.acpxrc.json",
            "mcp": "<cwd>/mcp.json"
          },
          "loaded": {
            "global": true,
            "project": false
          }
        }
        """

    private static let expectedJSON = #"""
        {"defaultAgent":"zeta","defaultPermissions":"deny-all","nonInteractivePermissions":"deny",\#
        "authPolicy":"skip","ttl":0.5,"timeout":90.5,"queueMaxDepth":4,"format":"text",\#
        "agents":{"zeta":{"command":"z"},"alpha":{"command":"a b"}},"authMethods":["a","b"],"disableExec":true,\#
        "paths":{"global":"<home>/.acpx/config.json","project":"<cwd>/.acpxrc.json","mcp":"<cwd>/mcp.json"},\#
        "loaded":{"global":true,"project":false}}
        """#

    @Test func configShowIsAcpxsDocument() async throws {
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            try Data(#"""
                {"defaultAgent": "zeta", "defaultPermissions": "deny-all", "ttl": 0.5, "timeout": 90.5,
                 "queueMaxDepth": 4, "format": "text", "disableExec": true,
                 "agents": {"zeta": {"command": "z"}, "Alpha": {"command": "a b"}}, "auth": {"b": "x", "a": "y"}}
                """#.utf8).write(to: ACPXPaths.globalConfigPath)
            let cwd = NSTemporaryDirectory() + "acpx-config-show-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            try Data(#"{"mcpServers": []}"#.utf8).write(to: URL(fileURLWithPath: cwd + "/mcp.json"))

            let document = ConfigCommand.document(try ConfigLoader.load(cwd: cwd, mcpConfigPath: "mcp.json"))
            func shown(_ text: String) -> String {
                text.replacingOccurrences(of: ACPXPaths.baseDir.path, with: "<home>/.acpx")
                    .replacingOccurrences(of: cwd, with: "<cwd>")
            }
            #expect(shown(document.pretty()) == Self.expectedText)
            #expect(shown(document.compact()) == Self.expectedJSON)
        }
    }

    /// A member with no value is left out, as `JSON.stringify` leaves out `undefined`;
    /// an explicit `null` is printed. The order is the order given.
    @Test func membersKeepTheirOrderAndAnAbsentOneIsLeftOut() {
        let document = jsonObject([
            ("zeta", .string("z")), ("absent", nil), ("alpha", .null), ("list", .array([.integer(1), .double(0.5)]))
        ] as [(String, JSONValue?)])
        #expect(document.compact() == #"{"zeta":"z","alpha":null,"list":[1,0.5]}"#)
    }
}
