@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// acpxd going away with a request it has is reported as acpx reports its queue owner
/// going away once it acknowledged one (`runQueueOwnerRequest`'s `onClose`): what came of
/// the request is unknown, `QUEUE_DISCONNECTED_BEFORE_COMPLETION`, not retryable.
@Suite(.serialized) struct DaemonDisconnectTests {
    /// What a CLI run came to.
    private struct Run {
        var code: Int32
        var out: String
        var err: String
    }

    /// `acpx --approve-all --agent stand-in --cwd <cwd> <args>`, with `daemon` the one running.
    private static func acpx(_ args: [String], cwd: URL, daemon: DroppingDaemon) async -> Run {
        let capture = Console.Capture()
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon.config) {
                    Console.$capture.withValue(capture) {
                        runCommandLine(["--approve-all", "--agent", "stand-in", "--cwd", cwd.path] + args)
                    }
                })
            }.start()
        }
        return Run(code: code, out: capture.out, err: capture.err)
    }

    /// A session for the stand-in agent in `cwd`.
    private static func session(in cwd: URL) throws {
        let now = nowISO()
        try SessionStore.writeRecord(SessionRecord(
            acpxRecordId: "gone-1", acpSessionId: "gone-1", agentCommand: "stand-in", cwd: cwd.path,
            createdAt: now, lastUsedAt: now))
    }

    @Test(.timeLimit(.minutes(1)))
    func aPromptWhoseDaemonGoesAwayHasAnUnknownOutcome() async throws {
        let daemon = try DroppingDaemon()
        defer { daemon.stop() }
        let cwd = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        try await withIsolatedStore {
            try Self.session(in: cwd)
            let text = await Self.acpx(["prompt", "hi"], cwd: cwd, daemon: daemon)
            #expect(text.code == 1)
            let said = "Queue owner disconnected before prompt completion; outcome unknown\n"
            #expect(text.err.hasSuffix(said), "\(text.err)")

            let json = await Self.acpx(["--format", "json", "prompt", "hi"], cwd: cwd, daemon: daemon)
            #expect(json.code == 1)
            #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"#
                + #""message":"Queue owner disconnected before prompt completion; outcome unknown","#
                + #""data":{"acpxCode":"RUNTIME","detailCode":"QUEUE_DISCONNECTED_BEFORE_COMPLETION","#
                + #""origin":"queue","retryable":false,"sessionId":"unknown"}}}"# + "\n")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aControlWhoseDaemonGoesAwayHasAnUnknownOutcome() async throws {
        let daemon = try DroppingDaemon()
        defer { daemon.stop() }
        let cwd = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        try await withIsolatedStore {
            try Self.session(in: cwd)
            for control in [["set-mode", "plan"], ["set", "effort", "high"], ["set", "model", "b"], ["cancel"]] {
                let text = await Self.acpx(control, cwd: cwd, daemon: daemon)
                #expect(text.code == 1, "\(control)")
                #expect(text.err == "Queue owner disconnected before responding; outcome unknown\n", "\(control)")
            }

            let json = await Self.acpx(["--format", "json", "set-mode", "plan"], cwd: cwd, daemon: daemon)
            #expect(json.code == 1)
            #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"#
                + #""message":"Queue owner disconnected before responding; outcome unknown","#
                + #""data":{"acpxCode":"RUNTIME","detailCode":"QUEUE_DISCONNECTED_BEFORE_COMPLETION","#
                + #""origin":"queue","retryable":false,"sessionId":"unknown"}}}"# + "\n")
        }
    }
}

/// A daemon stand-in on a loopback port: it answers MCP's handshake, then — as an acpxd
/// that goes away with the request — closes the connection as a tool call arrives, all but
/// `sessionStatus`, which it refuses.
final class DroppingDaemon: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32

    var config: MCPServerConfig {
        .tcp(config: MCPServerTcpConfig(host: "127.0.0.1", port: port))
    }

    init() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let listener = listener
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EIO) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        Thread { Self.acceptConnections(on: listener) }.start()
    }

    /// Stop taking connections.
    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private static func acceptConnections(on listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            Thread { serve(connection) }.start()
        }
    }

    private static func serve(_ connection: Int32) {
        defer { close(connection) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            pending.append(contentsOf: chunk[0 ..< count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] else { continue }
                let params = message["params"] as? [String: Any]
                var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
                switch message["method"] as? String {
                case "initialize":
                    reply["result"] = [
                        "protocolVersion": params?["protocolVersion"] ?? "2025-06-18",
                        "capabilities": ["tools": [String: Any](), "logging": [String: Any]()],
                        "serverInfo": ["name": "acpxd", "version": "0"]
                    ]
                case "tools/list":
                    reply["result"] = ["tools": [Any]()]
                case "tools/call" where params?["name"] as? String == "sessionStatus":
                    reply["error"] = ["code": -32603, "message": "not here"]
                case "tools/call":
                    return
                default:
                    reply["result"] = [String: Any]()
                }
                guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
                data.append(0x0A)
                _ = data.withUnsafeBytes { write(connection, $0.baseAddress, data.count) }
            }
        }
    }
}
