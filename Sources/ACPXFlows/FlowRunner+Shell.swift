import ACPXCore
import Foundation
import SwiftACP

// Shell actions and a function action's `ctx.runShell`, as acpx's runner runs them
// (`executeShellNode`, `runCallbackShell`, `shellControl`, v0.19.3). Split from
// `FlowRunner.swift` to keep each file inside the 500-line limit.
extension FlowRunner {
    /// acpx's `executeShellNode`: the node's `exec`, its command run — the step showing it,
    /// its output kept as artifacts, both traced — and `parse`, if it has one, on the
    /// result.
    func executeShellNode(_ node: FlowNode, attempt: FlowAttempt, runDir: URL) async throws -> Executed {
        let execution = try await invoke(node, "exec", attempt: attempt)
        try attempt.assertActive()
        // acpx reads `execution.cwd`, which an `exec` that gave nothing fails on.
        if execution == .undefined || execution == .json(.null) {
            let nothing = execution == .undefined ? "undefined" : "null"
            throw FlowShellError("Cannot read properties of \(nothing) (reading 'cwd')")
        }
        let spec = FlowShellExecution(json: execution.json ?? .object([WireJSON.Member]()))
        let cwd = try FlowShell.resolveCwd(options.defaultCwd, spec.cwd)
        // `execution.timeoutMs ?? attempt.remainingTimeoutMs()`: the rest of the node's time
        // only when the command gives none.
        let timeout: WireJSON?
        switch spec.timeoutMs {
        case nil, .null?: timeout = FlowShell.resolveTimeout(try attempt.remainingTimeoutMs().map(WireJSON.number))
        case let given?: timeout = FlowShell.resolveTimeout(given)
        }
        let effective = spec.with(cwd: cwd, timeoutMs: timeout)
        state.updateStatusDetail(FlowShell.summary(of: effective))
        let (nodeId, attemptId) = (attempt.nodeId, attempt.attemptId)
        try await attempt.own {
            try await self.writeShellStatus(runDir, nodeId: nodeId, attemptId: attemptId)
        }
        let prepared: WireJSON = .object([
            ("actionType", .text("shell")), ("command", effective.json["command"]),
            ("args", effective.json["args"] ?? .array([])), ("cwd", .text(cwd))
        ])
        try await attempt.own {
            try await self.appendActionTrace(
                runDir, "action_prepared", nodeId: nodeId, attemptId: attemptId,
                payload: .object([("action", prepared)]))
        }
        let control = shellControl(attempt)
        let result = try await attempt.own {
            try await FlowShellProcess.runAction(effective, cwd: cwd, control: control)
        }
        let stdoutArtifact = try await attempt.own {
            try await self.writeTextArtifact(runDir, result.stdout, nodeId: nodeId, attemptId: attemptId)
        }
        let stderrArtifact = try await attempt.own {
            try await self.writeTextArtifact(runDir, result.stderr, nodeId: nodeId, attemptId: attemptId)
        }
        let action: WireJSON = .object([
            ("actionType", .text("shell")), ("command", .text(result.command)),
            ("args", .array(result.args.map(WireJSON.text))), ("cwd", .text(result.cwd)),
            ("exitCode", result.exitCode.map { .number(Double($0)) } ?? .null),
            ("signal", result.signal.map(WireJSON.text) ?? .null), ("durationMs", .number(result.durationMs))
        ])
        try await attempt.own {
            try await self.appendActionTrace(
                runDir, "action_completed", nodeId: nodeId, attemptId: attemptId,
                payload: .object([
                    ("action", action), ("stdoutArtifact", stdoutArtifact.wire), ("stderrArtifact", stderrArtifact.wire)
                ]))
        }
        var trace = FlowStepTrace()
        trace["action"] = action
        trace["stdoutArtifact"] = stdoutArtifact.wire
        trace["stderrArtifact"] = stderrArtifact.wire
        let parsed = node.callbacks.contains("parse")
        let output: FlowValue
        do {
            output = parsed
                ? try await invoke(node, "parse", attempt: attempt, argument: result.wire(timedOut: false))
                : .json(result.wire(timedOut: false))
            try attempt.assertActive()
        } catch {
            throw FlowTracedError(underlying: error, trace: trace)
        }
        return Executed(output: output, outputFromHost: parsed, rawText: result.combinedOutput, trace: trace)
    }

    /// acpx's `runCallbackShell`: a function action's `ctx.runShell`, as work its attempt
    /// owns — so only while the attempt still takes work — its cwd resolved as a shell
    /// action's is.
    func runCallbackShell(_ params: WireJSON?) async throws -> WireJSON {
        let attemptId = params?["attemptId"]?.stringValue ?? ""
        guard let attempt = attempts[attemptId] else {
            throw (retiredAttempts[attemptId] ?? nil) ?? FlowAttemptFinished()
        }
        let spec = FlowShellExecution(json: params?["execution"] ?? .object([WireJSON.Member]()))
        let cwd = try FlowShell.resolveCwd(options.defaultCwd, spec.cwd)
        let control = shellControl(attempt)
        let result = try await attempt.own {
            try await FlowShellProcess.runCommand(spec, cwd: cwd, control: control)
        }
        return result.wire(timedOut: true)
    }

    /// acpx's `shellControl`: a command stopped when its attempt is cancelled, with the
    /// attempt's termination signal, and by the run when it is interrupted.
    func shellControl(_ attempt: FlowAttempt) -> FlowShellControl {
        let owners = shellOwners
        return FlowShellControl(attempt: attempt, registerOwner: { owner in
            let releaseAttempt = attempt.registerCancellation { signal in try await owner.cancel(signal) }
            let releaseRun = owners.register(owner)
            return {
                releaseAttempt()
                releaseRun()
            }
        })
    }

    private func writeShellStatus(_ runDir: URL, nodeId: String, attemptId: String) throws {
        try store.writeLive(
            runDir, &state, scope: "node", type: "node_heartbeat", nodeId: nodeId, attemptId: attemptId,
            payload: .object([("statusDetail", state["statusDetail"].map(WireJSON.text))]))
    }

    private func appendActionTrace(
        _ runDir: URL, _ type: String, nodeId: String, attemptId: String, payload: WireJSON
    ) throws {
        try store.appendTrace(runDir, state, scope: "action", type: type, nodeId: nodeId, attemptId: attemptId,
                              payload: payload)
    }

    private func writeTextArtifact(_ runDir: URL, _ text: String, nodeId: String, attemptId: String) throws
        -> FlowArtifactRef {
        try store.writeArtifact(
            runDir, state, content: .text(Array(text.utf16)), mediaType: "text/plain", extension: "txt",
            nodeId: nodeId, attemptId: attemptId)
    }
}

/// acpx's `shellOwners` for one run: the owners of its shell commands, which an interrupt
/// stops with its signal, and which the run lets go of when it ends.
final class FlowShellOwners: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [UUID: FlowShellOwner] = [:]

    func register(_ owner: FlowShellOwner) -> @Sendable () -> Void {
        let id = UUID()
        lock.withLock { owners[id] = owner }
        return { [weak self] in _ = self?.lock.withLock { self?.owners.removeValue(forKey: id) } }
    }

    /// acpx's `cancelShellOwners`: each stopped with `signal`, all waited for, and their
    /// failures one.
    func cancelAll(_ signal: String) async throws {
        let all = lock.withLock { Array(owners.values) }
        let errors: [Error] = await withTaskGroup(of: Error?.self) { group in
            for owner in all {
                group.addTask {
                    do {
                        try await owner.cancel(signal)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var errors: [Error] = []
            for await error in group { if let error { errors.append(error) } }
            return errors
        }
        if !errors.isEmpty { throw FlowShellCleanupError("Shell process cleanup failed", errors: errors) }
    }

    /// acpx's `releaseShellOwners`.
    func releaseAll() {
        let all: [FlowShellOwner] = lock.withLock {
            defer { owners.removeAll() }
            return Array(owners.values)
        }
        for owner in all { owner.release() }
    }
}

extension FlowShell {
    /// acpx's `resolveShellActionCwd`: `path.resolve(defaultCwd, cwd ?? defaultCwd)`.
    static func resolveCwd(_ defaultCwd: String, _ cwd: WireJSON?) throws -> String {
        switch cwd {
        case nil, .null?: return ACPXPaths.resolve(defaultCwd, base: defaultCwd)
        case .string(let units)?: return ACPXPaths.resolve(String(decoding: units, as: UTF16.self), base: defaultCwd)
        case let other?:
            throw FlowShellError.invalidArgType(NodeArgumentError.type("paths[1]", "of type string", other))
        }
    }

    /// acpx's `formatShellActionSummary` of the spec as given: the command as JavaScript's
    /// template string makes it, each argument as `JSON.stringify` writes it.
    static func summary(of spec: FlowShellExecution) -> String {
        let command = SessionArchive.javaScriptString(spec.json["command"])
        var args: [WireJSON] = []
        if case .array(let items)? = spec.json["args"] { args = items }
        let rendered = args.map { $0.stringified }.joined(separator: " ")
        return "shell: " + (rendered.isEmpty ? command : "\(command) \(rendered)")
    }
}

extension FlowShellExecution {
    /// acpx's `{ ...execution, cwd, timeoutMs }`.
    func with(cwd: String, timeoutMs: WireJSON?) -> FlowShellExecution {
        var members = json.objectMembers
        func set(_ key: String, _ value: WireJSON?) {
            let units = Array(key.utf16)
            if let index = members.firstIndex(where: { $0.key == units }) {
                if let value { members[index].value = value } else { members.remove(at: index) }
            } else if let value {
                members.append(WireJSON.Member(key, value))
            }
        }
        set("cwd", .text(cwd))
        set("timeoutMs", timeoutMs)
        return FlowShellExecution(json: .object(members))
    }
}
