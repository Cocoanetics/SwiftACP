import Foundation
import JSONFoundation

// Serving the agent's `fs/*` requests: containment in acpx's two stages, the write
// permission question between them, and acpx's error shapes on the way back.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit;
// the members this reaches are internal rather than private so both halves can.
extension ACPAgentConnection {
    /// Serve one `fs/*` request, confining its path to the session's working directory
    /// first (see ``FileSystemAccessScope``). The handler only ever sees a path the
    /// client has already vouched for, so a custom handler inherits the containment.
    ///
    /// A session this connection never opened has no root to check against, so its
    /// requests are refused rather than served unchecked — an agent cannot reach out of
    /// the workspace by naming a session id we do not know.
    func routeFileSystem<
        Request: FileSystemPathRequest & Decodable & Sendable, Response: Encodable & Sendable
    >(
        _ method: String, _ params: JSONValue?, access: FileSystemContainment.Access,
        _ handler: (@Sendable (Request) async throws -> Response)?,
        authorize: (@Sendable (Request) async throws -> Void)? = nil
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard let handler else { return .failure(Self.methodNotFound(method)) }
        var named: String?
        do {
            var request: Request = try decode(params)
            named = request.path
            if fileSystemAccess == .sessionRoot {
                guard let root = sessionRoots[request.sessionId] else {
                    return .failure(.invalidParams("Unknown session: \(request.sessionId)"))
                }
                // acpx's order: the lexical check, then the permission question, then
                // the disk. A path plainly outside the workspace is refused without
                // asking; one that only turns out to escape on disk is asked about
                // first, as it is upstream.
                named = try FileSystemContainment.lexicallyContained(request.path, under: root)
                try await authorize?(request)
                request.path = try FileSystemContainment.resolveWithinRealRoot(request.path, under: root)
            } else {
                try await authorize?(request)
            }
            let contained = request
            let response = try await handler(contained)
            return .success(try JSONValue(encoding: response))
        } catch let error as JSONRPCErrorBody where error.code == FileSystemContainment.resourceNotFoundCode {
            // The handler opened the resolved path; the agent should hear back about
            // the path *it* named, as acpx builds the URI from the request.
            return .failure(named.map(FileSystemContainment.resourceNotFound) ?? error)
        } catch let error as JSONRPCErrorBody {
            return .failure(error)
        } catch let error as FileSystemPermissionError {
            if let sessionId = decodedSessionId(params) {
                turnPermissionStats[sessionId, default: PermissionStats()]
                    .record(error == .promptUnavailable ? .cancelled : .denied)
                if error == .promptUnavailable {
                    turnPermissionStats[sessionId]?.promptUnavailable = true
                }
            }
            return .failure(FileSystemContainment.refused(error.description))
        } catch {
            // Anything else a handler throws reaches the agent the way the ACP SDK
            // reports a thrown error: `Internal error`, the message in `data.details`.
            return .failure(FileSystemContainment.refused(error.localizedDescription))
        }
    }

    /// The `sessionId` a request names, for bookkeeping after its handler failed.
    func decodedSessionId(_ params: JSONValue?) -> SessionId? {
        guard case .object(let object)? = params, case .string(let id)? = object["sessionId"]
        else { return nil }
        return id
    }
}
