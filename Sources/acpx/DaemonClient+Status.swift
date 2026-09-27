import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

// Whether acpxd holds a session, for the prompt banner and `status`: where acpx probes
// the session's queue owner (`probeQueueOwnerHealth`). Split from `DaemonClient.swift`.
extension DaemonClient {
    /// What acpxd says of a session — acpx's queue owner health, in acpxd's terms.
    enum SessionHold: Equatable {
        /// A daemon holds it live, as acpx's healthy owner does: its agent's pid while it
        /// runs.
        case held(pid: Int?)
        /// Nothing holds it: no daemon runs, or the one running does not hold it — acpx's
        /// session with no lease.
        case notHeld
        /// A daemon holds the lock but does not answer — acpx's owner whose lease is held
        /// and whose socket cannot be reached.
        case unreachable
        /// A daemon answers, but cannot say: one from before it could.
        case unknown
    }

    /// Ask the running daemon whether it holds `sessionId`. Never starts one. A daemon
    /// holding the lock with no port recorded — starting, or with a lock that says none —
    /// is one that does not answer, as one that cannot be reached at its port is.
    static func sessionHold(sessionId: String) async -> SessionHold {
        guard let holder = liveHolder() else { return .notHeld }
        guard let endpoint = endpoint(of: holder),
              let proxy = await tryConnect(endpoint, configure: { _ in })
        else { return .unreachable }
        let hold = await sessionHold(on: proxy, sessionId: sessionId)
        await proxy.disconnect()
        return hold
    }

    /// Whether acpxd holds `sessionId` as acpx's queue owner holds one (``LiveSessionStatus/owned``).
    /// Never starts a daemon; one that cannot say holds none.
    static func sessionOwned(sessionId: String) async -> Bool {
        guard let proxy = try? await connect(spawnIfNeeded: false) else { return false }
        let status = try? await ACPXDaemon.Client(proxy: proxy).sessionStatus(sessionId: sessionId)
        await proxy.disconnect()
        return status?.owned == true
    }

    /// acpx's line under `--verbose` for a request its CLI handed to the session's running owner
    /// (`trySubmitToRunningOwner`, `tryControlOnRunningOwner`): `<said> <pid> for session
    /// <recordId>`, the pid acpxd's, which holds every session as acpx's owner holds one (#232).
    static func noteOwner(_ said: String, recordId: String) {
        guard let pid = daemonPid() else { return }
        Console.errLine("[acpx] \(said) \(pid) for session \(recordId)")
    }

    /// The pid of the acpxd this CLI talks to: its lock's holder, or this process for one a test
    /// stands in for (``standIn``), which runs here.
    static func daemonPid() -> Int32? {
        standIn != nil ? ProcessInfo.processInfo.processIdentifier : liveHolder()?.pid
    }

    /// Whether the daemon `proxy` is connected to holds `sessionId`. A daemon that answers
    /// without saying — one from before the tool, which does not know it — cannot say; one
    /// that stopped answering once connected is one that does not answer.
    static func sessionHold(on proxy: MCPServerProxy, sessionId: String) async -> SessionHold {
        do {
            let status = try await ACPXDaemon.Client(proxy: proxy).sessionStatus(sessionId: sessionId)
            return status.live ? .held(pid: status.pid) : .notHeld
        } catch MCPServerProxyError.toolError, is DecodingError {
            return .unknown
        } catch {
            return .unreachable
        }
    }
}
