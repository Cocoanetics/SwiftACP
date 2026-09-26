import ACPXCore
import Foundation
import SwiftACP

#if canImport(Darwin)
import Darwin
#endif

/// acpx's `FlowRunStore` (`src/flows/store.ts`, v0.19.3): the run bundle under
/// `~/.acpx/flows/runs/<runId>/`, written as acpx writes it — JSON as
/// `JSON.stringify(value, null, 2)` and a newline, each file whole under a temporary
/// name and moved into place, owner-only; the trace one JSON line per event; artifacts
/// named for the SHA-256 of what they hold.
struct FlowRunStore {
    static let bundleSchema = "acpx.flow-run-bundle.v1"
    static let traceSchema = "acpx.flow-trace-event.v1"

    let outputRoot: URL
    private var traceSeq = 0
    private var manifest: JSObject?

    init(outputRoot: URL) {
        self.outputRoot = outputRoot
    }

    // MARK: - The run

    /// acpx's `createRunDir`.
    mutating func createRunDir(_ runId: String) throws -> URL {
        let runDir = outputRoot.appendingPathComponent(runId, isDirectory: true)
        for directory in ["projections", "sessions", "artifacts"] {
            try FileManager.default.createDirectory(
                at: runDir.appendingPathComponent(directory), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        traceSeq = 0
        return runDir
    }

    /// acpx's `initializeRunBundle`.
    mutating func initializeRunBundle(
        _ runDir: URL, snapshot: WireJSON, state: FlowRunState, inputArtifact: FlowArtifactRef?
    ) throws {
        let manifest = Self.createRunManifest(state)
        self.manifest = manifest
        try Self.writeJSON(snapshot, to: runDir.appendingPathComponent("flow.json"))
        try Self.writeJSON(manifest.wire, to: runDir.appendingPathComponent("manifest.json"))
        try Self.writeJSON(state.wire, to: runDir.appendingPathComponent("projections/run.json"))
        try Self.writeJSON(state.live, to: runDir.appendingPathComponent("projections/live.json"))
        try Self.writeJSON(.array(state.steps), to: runDir.appendingPathComponent("projections/steps.json"))
        try Self.append(Data(), to: runDir.appendingPathComponent("trace.ndjson"))
        let runTitle = state["runTitle"]
        let flowPath = state["flowPath"]
        try appendTrace(runDir, state, scope: "run", type: "run_started", payload: .object([
            ("flowName", .text(state.flowName)),
            ("runTitle", runTitle.flatMap { $0.isEmpty ? nil : WireJSON.text($0) }),
            ("flowPath", flowPath.flatMap { $0.isEmpty ? nil : WireJSON.text($0) }),
            ("inputArtifact", inputArtifact?.wire)
        ]))
    }

    /// acpx's `writeSnapshot`: every projection and the manifest, then the event.
    mutating func writeSnapshot(
        _ runDir: URL, _ state: inout FlowRunState, scope: String, type: String, nodeId: String? = nil,
        attemptId: String? = nil, payload: WireJSON
    ) throws {
        state["updatedAt"] = nowISO()
        try Self.writeJSON(state.wire, to: runDir.appendingPathComponent("projections/run.json"))
        try Self.writeJSON(state.live, to: runDir.appendingPathComponent("projections/live.json"))
        try Self.writeJSON(.array(state.steps), to: runDir.appendingPathComponent("projections/steps.json"))
        try writeManifest(runDir, state)
        try appendTrace(runDir, state, scope: scope, type: type, nodeId: nodeId, attemptId: attemptId, payload: payload)
    }

    /// acpx's `writeLive`: the live projection and the manifest, then the event.
    mutating func writeLive(
        _ runDir: URL, _ state: inout FlowRunState, scope: String, type: String, nodeId: String? = nil,
        attemptId: String? = nil, payload: WireJSON
    ) throws {
        state["updatedAt"] = nowISO()
        try Self.writeJSON(state.live, to: runDir.appendingPathComponent("projections/live.json"))
        try writeManifest(runDir, state)
        try appendTrace(runDir, state, scope: scope, type: type, nodeId: nodeId, attemptId: attemptId, payload: payload)
    }

    /// acpx's `appendTrace`: `{seq, at, runId, ...event}`.
    mutating func appendTrace(
        _ runDir: URL, _ state: FlowRunState, scope: String, type: String, nodeId: String? = nil,
        attemptId: String? = nil, sessionId: String? = nil, artifact: FlowArtifactRef? = nil, payload: WireJSON
    ) throws {
        traceSeq += 1
        let event: WireJSON = .object([
            ("seq", .number(Double(traceSeq))), ("at", .text(nowISO())), ("runId", .text(state.runId)),
            ("scope", .text(scope)), ("type", .text(type)), ("nodeId", nodeId.map(WireJSON.text)),
            ("attemptId", attemptId.map(WireJSON.text)), ("sessionId", sessionId.map(WireJSON.text)),
            ("artifact", artifact?.wire), ("payload", payload)
        ])
        try Self.append(Data((event.stringified + "\n").utf8), to: runDir.appendingPathComponent("trace.ndjson"))
    }

    /// What an artifact holds: text as it is, or a value as JSON.
    enum ArtifactContent {
        case text([UInt16])
        case value(FlowValue)
    }

    /// acpx's `writeArtifact`: the content under `artifacts/sha256-<hex>.<extension>`,
    /// written only if no artifact holds it yet, and an `artifact_written` event unless
    /// `emitTrace` is false.
    mutating func writeArtifact(
        _ runDir: URL, _ state: FlowRunState, content: ArtifactContent, mediaType: String, extension ext: String,
        nodeId: String? = nil, attemptId: String? = nil, sessionId: String? = nil, emitTrace: Bool = true
    ) throws -> FlowArtifactRef {
        let buffer = Self.artifactBuffer(content, mediaType: mediaType)
        let sha256 = FlowRuntimeSupport.sha256Hex(buffer)
        let suffix = ext.isEmpty ? "" : (ext.hasPrefix(".") ? ext : ".\(ext)")
        let relativePath = "artifacts/sha256-\(sha256)\(suffix)"
        let file = runDir.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: file.path) {
            try Self.writePrivateFile(buffer, to: file)
        }
        let artifact = FlowArtifactRef(path: relativePath, mediaType: mediaType, bytes: buffer.count, sha256: sha256)
        if emitTrace {
            try appendTrace(
                runDir, state, scope: "artifact", type: "artifact_written", nodeId: nodeId, attemptId: attemptId,
                sessionId: sessionId, artifact: artifact, payload: .object([("artifact", artifact.wire)]))
        }
        return artifact
    }

    // MARK: - The manifest

    /// acpx's `getManifest`: the one made at the start, its run fields brought up to date.
    private mutating func currentManifest(_ state: FlowRunState) -> JSObject {
        var manifest = self.manifest ?? Self.createRunManifest(state)
        manifest["startedAt"] = state["startedAt"].map(WireJSON.text)
        manifest["finishedAt"] = state["finishedAt"].map(WireJSON.text)
        manifest["status"] = .text(state.status)
        manifest["flowPath"] = state["flowPath"].map(WireJSON.text)
        manifest["flowName"] = .text(state.flowName)
        manifest["runTitle"] = state["runTitle"].map(WireJSON.text)
        self.manifest = manifest
        return manifest
    }

    private mutating func writeManifest(_ runDir: URL, _ state: FlowRunState) throws {
        try Self.writeJSON(currentManifest(state).wire, to: runDir.appendingPathComponent("manifest.json"))
    }

    /// acpx's `createRunManifest`.
    private static func createRunManifest(_ state: FlowRunState) -> JSObject {
        var manifest = JSObject()
        manifest["schema"] = .text(bundleSchema)
        manifest["runId"] = .text(state.runId)
        manifest["flowName"] = .text(state.flowName)
        manifest["runTitle"] = state["runTitle"].map(WireJSON.text)
        manifest["flowPath"] = state["flowPath"].map(WireJSON.text)
        manifest["startedAt"] = state["startedAt"].map(WireJSON.text)
        manifest["finishedAt"] = state["finishedAt"].map(WireJSON.text)
        manifest["status"] = .text(state.status)
        manifest["traceSchema"] = .text(traceSchema)
        manifest["paths"] = .object([
            ("flow", .text("flow.json")), ("trace", .text("trace.ndjson")),
            ("runProjection", .text("projections/run.json")), ("liveProjection", .text("projections/live.json")),
            ("stepsProjection", .text("projections/steps.json")), ("sessionsDir", .text("sessions")),
            ("artifactsDir", .text("artifacts"))
        ])
        manifest["sessions"] = .array([])
        return manifest
    }

    // MARK: - Files

    /// acpx's `toArtifactBuffer`: text as UTF-8; anything else JSON-typed as
    /// `JSON.stringify(content, null, 2)` and a newline.
    static func artifactBuffer(_ content: ArtifactContent, mediaType: String) -> Data {
        switch content {
        case .text(let units):
            return Data(String(decoding: units, as: UTF16.self).utf8)
        case .value(let value):
            if case .string(let units)? = value.json {
                return Data(String(decoding: units, as: UTF16.self).utf8)
            }
            let text: String
            switch value {
            case .json(let json):
                text = mediaType == "application/json" ? json.stringified(indent: 2) : json.stringified
            case .undefined, .unrepresentable, .unserializable: text = "undefined"
            }
            return Data((mediaType == "application/json" ? text + "\n" : text).utf8)
        }
    }

    /// acpx's `writePrivateJsonFile`.
    static func writeJSON(_ value: WireJSON, to file: URL) throws {
        try writePrivateFile(Data((value.stringified(indent: 2) + "\n").utf8), to: file)
    }

    /// acpx's `writePrivateFile`: the directory made owner-only, the file written whole
    /// under a temporary name beside it (mode 0600), then moved into place.
    static func writePrivateFile(_ data: Data, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(directory.path, 0o700)
        let temporary = directory.appendingPathComponent(".acpx-write-\(UUID().uuidString.lowercased())")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try writeAll(descriptor, data)
            _ = fchmod(descriptor, 0o600)
            close(descriptor)
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, file.path) == 0 else {
            let failure = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// acpx's `appendRegularFile`: appended to, created owner-only if missing.
    static func append(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try writeAll(descriptor, data)
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }
}
