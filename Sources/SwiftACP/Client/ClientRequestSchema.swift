import Foundation
import JSONFoundation

/// The ACP SDK's schema for a request an agent sends its client
/// (`@agentclientprotocol/sdk` 1.5.0, `schema/zod.gen.js`), as acpx's client applies it
/// before serving the request.
///
/// A member the schema requires, missing or of another type, fails the request: the SDK
/// answers `Invalid params`, with zod's `format()` of every such issue as its `data`
/// (``issues(in:at:)``, ``formatted(_:)``). Every other member it reads leniently
/// (`defaultOnError`): one that does not fit is read as absent — a list as empty, or
/// without the entries that do not fit (`vecSkipError`) — and never fails the request
/// (``lenient(_:)``).
indirect enum ClientRequestSchema: Sendable {
    case string
    /// `z.number()`: any number.
    case number
    /// `z.int().gte(0).max(4294967295)`.
    case uint32
    /// `z.record(z.string(), z.unknown())`: any object.
    case record
    /// `z.unknown()`: anything.
    case unknown
    /// String literals, any one of which fits.
    case literals([String])
    case object([Member])
    case array(ClientRequestSchema)
    /// The first of these that fits (`z.union`).
    case union([ClientRequestSchema])

    /// A member of an object, and how the schema reads it.
    struct Member: Sendable {
        let name: String
        let schema: ClientRequestSchema
        let reading: Reading
    }

    enum Reading: Sendable {
        /// It must be there, and fit.
        case required
        /// `defaultOnError(schema.nullish(), () => undefined)`: absent or null as it is,
        /// and dropped when it does not fit.
        case dropped
        /// `defaultOnError(vecSkipError(item).optional(), () => [])`: a list without the
        /// entries that do not fit; anything else there is an empty one.
        case listOrEmpty
        /// `defaultOnError(vecSkipError(item).nullish(), () => undefined)`: a list without
        /// the entries that do not fit, null as it is, and anything else dropped.
        case listOrDropped
    }

    /// One way params do not fit: where, and zod's message for it.
    struct Issue: Equatable, Sendable {
        let path: [String]
        let message: String
    }
}

// MARK: - Checking

extension ClientRequestSchema {
    /// Every way `value` — `nil` when absent — does not fit, in the order zod finds them.
    func issues(in value: JSONValue?, at path: [String] = []) -> [Issue] {
        switch self {
        case .unknown:
            return []
        case .string, .number, .uint32, .record:
            return fitsScalar(value) ? [] : [Issue(path: path, message: Self.expected(typeName, value))]
        case .literals(let literals):
            if case .string(let text)? = value, literals.contains(text) { return [] }
            return literals.map { Issue(path: path, message: "Invalid input: expected \(Self.quoted($0))") }
        case .object(let members):
            guard case .object(let object)? = value else {
                return [Issue(path: path, message: Self.expected("object", value))]
            }
            return members.filter { $0.reading == .required }.flatMap { member in
                member.schema.issues(in: object[member.name], at: path + [member.name])
            }
        case .array(let item):
            guard case .array(let items)? = value else {
                return [Issue(path: path, message: Self.expected("array", value))]
            }
            return items.enumerated().flatMap { index, entry in item.issues(in: entry, at: path + [String(index)]) }
        case .union(let options):
            return options.contains { $0.fits(value) } ? [] : [Issue(path: path, message: "Invalid input")]
        }
    }

    func fits(_ value: JSONValue?) -> Bool {
        issues(in: value).isEmpty
    }

    private var typeName: String {
        switch self {
        case .number: return "number"
        case .uint32: return "int"
        case .record: return "record"
        default: return "string"
        }
    }

    private func fitsScalar(_ value: JSONValue?) -> Bool {
        switch (self, value) {
        case (.string, .string?), (.record, .object?): return true
        case (.number, .integer?), (.number, .unsignedInteger?), (.number, .double?): return true
        case (.uint32, .integer(let number)?): return (0...4_294_967_295).contains(number)
        case (.uint32, .unsignedInteger(let number)?): return number <= 4_294_967_295
        case (.uint32, .double(let number)?): return number.rounded() == number && (0...4_294_967_295).contains(number)
        default: return false
        }
    }

    /// zod's `invalid_type` message.
    private static func expected(_ type: String, _ value: JSONValue?) -> String {
        "Invalid input: expected \(type), received \(received(value))"
    }

    /// The type zod names for `value`.
    private static func received(_ value: JSONValue?) -> String {
        switch value {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool?: return "boolean"
        case .integer?, .unsignedInteger?, .double?: return "number"
        case .string?: return "string"
        case .array?: return "array"
        case .object?: return "object"
        }
    }

    /// `JSON.stringify` of a literal, as zod quotes it.
    private static func quoted(_ literal: String) -> String {
        let data = (try? JSONEncoder().encode(literal)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// zod's `error.format()` of `issues`: each message under its path, and every level's
    /// own messages in `_errors`.
    static func formatted(_ issues: [Issue]) -> JSONValue {
        var root = FormattedLevel()
        for issue in issues { root.add(issue.message, at: issue.path[...]) }
        return root.value
    }

    private struct FormattedLevel {
        var errors: [String] = []
        var levels: [String: FormattedLevel] = [:]

        mutating func add(_ message: String, at path: ArraySlice<String>) {
            guard let first = path.first else {
                errors.append(message)
                return
            }
            levels[first, default: FormattedLevel()].add(message, at: path.dropFirst())
        }

        var value: JSONValue {
            var object: [String: JSONValue] = ["_errors": .array(errors.map { .string($0) })]
            for (name, level) in levels { object[name] = level.value }
            return .object(object)
        }
    }
}

// MARK: - Reading leniently

extension ClientRequestSchema {
    /// `value`, which fits, as the SDK reads it: each member read leniently as its
    /// `defaultOnError` leaves it — dropped, emptied, or a list without the entries that
    /// do not fit — and everything else as it is.
    func lenient(_ value: JSONValue) -> JSONValue {
        switch (self, value) {
        case (.object(let members), .object(var object)):
            for member in members {
                guard let current = object[member.name] else { continue }
                object[member.name] = member.lenient(current)
            }
            return .object(object)
        case (.array(let item), .array(let items)):
            return .array(items.map(item.lenient))
        case (.union(let options), _):
            return options.first { $0.fits(value) }?.lenient(value) ?? value
        default:
            return value
        }
    }
}

extension ClientRequestSchema.Member {
    /// This member's value `value` as the SDK reads it; `nil` when it is dropped.
    fileprivate func lenient(_ value: JSONValue) -> JSONValue? {
        switch reading {
        case .required:
            return schema.lenient(value)
        case .dropped:
            // Not `fits ? lenient : nil`: that `nil` would be `JSONValue.null`, a member
            // kept as null rather than dropped.
            guard value == .null || schema.fits(value) else { return nil }
            return schema.lenient(value)
        case .listOrEmpty, .listOrDropped:
            guard case .array(let items) = value, case .array(let item) = schema else {
                if reading == .listOrEmpty { return .array([]) }
                guard value == .null else { return nil }
                return value
            }
            return .array(items.filter { item.fits($0) }.map(item.lenient))
        }
    }
}

// MARK: - The requests acpx's client serves

extension ClientRequestSchema {
    /// The schema of the request `method` names, for the methods acpx's client serves.
    static func request(_ method: String) -> ClientRequestSchema? {
        switch method {
        case "fs/read_text_file":
            return .object([
                required("sessionId", .string), required("path", .string),
                dropped("line", .uint32), dropped("limit", .uint32), meta
            ])
        case "fs/write_text_file":
            return .object([
                required("sessionId", .string), required("path", .string), required("content", .string), meta
            ])
        case "terminal/create":
            return .object([
                required("sessionId", .string), required("command", .string),
                Member(name: "args", schema: .array(.string), reading: .listOrEmpty),
                Member(name: "env", schema: .array(envVariable), reading: .listOrEmpty),
                dropped("cwd", .string), dropped("outputByteLimit", .number), meta
            ])
        case "terminal/output", "terminal/release", "terminal/wait_for_exit", "terminal/kill":
            return .object([required("sessionId", .string), required("terminalId", .string), meta])
        case "session/request_permission":
            return .object([
                required("sessionId", .string), required("toolCall", toolCallUpdate),
                required("options", .array(permissionOption)), meta
            ])
        default:
            return nil
        }
    }

    private static func required(_ name: String, _ schema: ClientRequestSchema) -> Member {
        Member(name: name, schema: schema, reading: .required)
    }

    private static func dropped(_ name: String, _ schema: ClientRequestSchema) -> Member {
        Member(name: name, schema: schema, reading: .dropped)
    }

    /// `_meta`, on every object.
    private static let meta = dropped("_meta", .record)

    /// `zEnvVariable`.
    private static let envVariable: ClientRequestSchema = .object([
        required("name", .string), required("value", .string), meta
    ])

    /// `zToolCallUpdate`.
    private static let toolCallUpdate: ClientRequestSchema = .object([
        required("toolCallId", .string),
        dropped("kind", .literals([
            "read", "edit", "delete", "move", "search", "execute", "think", "fetch", "switch_mode", "other"
        ])),
        dropped("status", .literals(["pending", "in_progress", "completed", "failed"])),
        dropped("title", .string), dropped("name", .string),
        Member(name: "content", schema: .array(toolCallContent), reading: .listOrDropped),
        Member(name: "locations", schema: .array(location), reading: .listOrDropped),
        dropped("rawInput", .unknown), dropped("rawOutput", .unknown), meta
    ])

    /// `zToolCallLocation`.
    private static let location: ClientRequestSchema = .object([
        required("path", .string), dropped("line", .uint32), meta
    ])

    /// `zPermissionOption`.
    private static let permissionOption: ClientRequestSchema = .object([
        required("optionId", .string), required("name", .string),
        required("kind", .literals(["allow_once", "allow_always", "reject_once", "reject_always"])), meta
    ])

    /// `zToolCallContent`: content, a diff or a terminal, told apart by `type`.
    private static let toolCallContent: ClientRequestSchema = .union([
        .object([required("type", .literals(["content"])), required("content", contentBlock), meta]),
        .object([
            required("type", .literals(["diff"])), required("path", .string), dropped("oldText", .string),
            required("newText", .string), meta
        ]),
        .object([required("type", .literals(["terminal"])), required("terminalId", .string), meta])
    ])

    /// `zContentBlock`.
    private static let contentBlock: ClientRequestSchema = .union([
        .object([required("type", .literals(["text"])), annotations, required("text", .string), meta]),
        .object([
            required("type", .literals(["image"])), annotations, required("data", .string),
            required("mimeType", .string), dropped("uri", .string), meta
        ]),
        .object([
            required("type", .literals(["audio"])), annotations, required("data", .string),
            required("mimeType", .string), meta
        ]),
        .object([
            required("type", .literals(["resource_link"])), annotations, dropped("description", .string),
            dropped("mimeType", .string), required("name", .string), dropped("size", .number),
            dropped("title", .string), required("uri", .string), meta
        ]),
        .object([required("type", .literals(["resource"])), annotations, required("resource", resource), meta])
    ])

    /// `zAnnotations`, which every content block may have.
    private static let annotations = dropped("annotations", .object([
        Member(name: "audience", schema: .array(.literals(["assistant", "user"])), reading: .listOrDropped),
        dropped("lastModified", .string), dropped("priority", .number), meta
    ]))

    /// `zEmbeddedResourceResource`: text or a blob.
    private static let resource: ClientRequestSchema = .union([
        .object([dropped("mimeType", .string), required("text", .string), required("uri", .string), meta]),
        .object([required("blob", .string), dropped("mimeType", .string), required("uri", .string), meta])
    ])
}
