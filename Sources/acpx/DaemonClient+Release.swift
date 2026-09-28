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
    /// the session (``ACPXDaemon/releaseSession(sessionId:turnToken:)``) — given a turn's
    /// token, of the agent that turn runs on, while it does. Never spawns a daemon.
    static func releaseSession(sessionId: String, turnToken: String? = nil) async -> Release {
        do {
            return .released(try await withClient(spawnIfNeeded: false) {
                try await $0.releaseSession(sessionId: sessionId, turnToken: turnToken)
            })
        } catch is DaemonUnavailable {
            return .noDaemon
        } catch {
            return .refused(error)
        }
    }

    /// Call off, on a *running* daemon, the session it makes under `creationToken`
    /// (``ACPXDaemon/callOffCreation(creationToken:)``), letting go of the agent that creation
    /// made. A daemon that is gone holds nothing. Never spawns a daemon.
    @discardableResult
    static func callOffCreation(_ creationToken: String) async -> Release {
        do {
            return .released(try await withClient(spawnIfNeeded: false) {
                try await $0.callOffCreation(creationToken: creationToken)
            })
        } catch is DaemonUnavailable {
            return .noDaemon
        } catch {
            return .refused(error)
        }
    }
}
