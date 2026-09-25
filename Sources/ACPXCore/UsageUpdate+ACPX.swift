import Foundation
import JSONFoundation
import SwiftACP

/// What of a `usage_update` reaches acpx. acpx 0.19.1's ACP SDK
/// (`@agentclientprotocol/sdk` 1.5.0) checks each against `zUsageUpdate` before acpx sees
/// it:
/// - `used` and `size` must be numbers, or the whole update is dropped;
/// - `cost` is kept only with a number `amount` and a string `currency` (`zCost`);
/// - `_meta` is kept only as an object;
/// - every other key is stripped.
///
/// So acpx's fallback to token counts on the update itself (`usageToTokenUsage`) never finds
/// any (#155).
extension UsageUpdate {
    /// Whether the update reaches acpx at all: its `used` and `size` are numbers.
    public var reachesACPX: Bool {
        guard case .object(let body)? = raw else { return used != nil && size != nil }
        return Self.isNumber(body["used"]) && Self.isNumber(body["size"])
    }

    /// The token breakdown acpx can read: `_meta.usage`, when `_meta` and `usage` are
    /// objects.
    public var acpxTokenUsage: [String: JSONValue]? {
        guard case .object(let meta)? = meta, case .object(let usage)? = meta["usage"] else { return nil }
        return usage
    }

    /// The cost acpx's SDK passes on (`zCost`): an amount and a currency, or none.
    public var acpxCost: (amount: Double, currency: String)? {
        guard let cost, let amount = cost.amount, let currency = cost.currency else { return nil }
        return (amount, currency)
    }

    private static func isNumber(_ value: JSONValue?) -> Bool {
        switch value {
        case .integer?, .unsignedInteger?, .double?: return true
        default: return false
        }
    }
}
