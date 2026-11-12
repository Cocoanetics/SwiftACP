import Foundation

extension WireJSON {
    /// acpx's `isAcpJsonRpcMessage`: a JSON-RPC 2.0 request, notification or response.
    public static func isACPMessage(_ value: WireJSON) -> Bool {
        guard case .object = value, value["jsonrpc"] == .text("2.0") else { return false }
        let hasMethod = value["method"]?.stringValue.map { !$0.isEmpty } ?? false
        let id = value["id"]
        let validId: Bool
        switch id {
        case .null?, .string?: validId = true
        case .number(let number)?: validId = number.isFinite
        default: validId = false
        }
        if hasMethod { return id == nil || validId }
        guard id != nil, validId else { return false }
        switch (value["result"], value["error"]) {
        case (.some, .none): return true
        case (.none, .some(let error)):
            guard case .number(let code)? = error["code"], code.isFinite, case .string? = error["message"] else {
                return false
            }
            return true
        default: return false
        }
    }
}
