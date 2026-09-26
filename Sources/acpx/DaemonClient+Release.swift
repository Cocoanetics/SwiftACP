import Foundation
import SwiftACP
import SwiftMCP

// Letting a session's agent go without closing the session, for `sessions new`. Split
// from `DaemonClient.swift`.
extension DaemonClient {
    /// What a running daemon made of being asked to let a session's agent go.
    enum Release {
        /// It did, saying whether it had the session.
        case released(Bool)
        /// None is running: nothing holds the session.
        case noDaemon
        /// One answered with this error, and may still hold the session.
        case refused(any Error)
    }

    /// Ask a *running* daemon to let go of its live agent for `sessionId` without closing
    /// the session (``ACPXDaemon/releaseSession(sessionId:)``). Never spawns a daemon.
    static func releaseSession(sessionId: String) async -> Release {
        do {
            return .released(try await withClient(spawnIfNeeded: false) {
                try await $0.releaseSession(sessionId: sessionId)
            })
        } catch is DaemonUnavailable {
            return .noDaemon
        } catch {
            return .refused(error)
        }
    }

    /// Whether a *running* daemon lacks ``ACPXDaemon/releaseSession(sessionId:)``: an acpxd
    /// from before it (#162), which lets a session's agent go only by closing the session.
    /// With none running, nothing holds a session, and nothing is lacking.
    static func lacksRelease() async -> Bool {
        guard let proxy = await tryConnectLive(configure: { _ in }) else { return false }
        let lacks = await lacksRelease(on: proxy)
        await proxy.disconnect()
        return lacks
    }

    /// Whether the daemon behind `proxy` lacks `releaseSession`, or cannot say what it has.
    static func lacksRelease(on proxy: MCPServerProxy) async -> Bool {
        guard let tools = try? await proxy.listTools() else { return true }
        return !tools.contains { $0.name == "releaseSession" }
    }
}
