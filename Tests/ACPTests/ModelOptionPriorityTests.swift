@testable import ACPXCore
import Foundation
import JSONFoundation
import Testing

/// Of several model select options, acpx takes the model's own — category `model`, id
/// `model` — then another in the `model` category, then one with the id `model` alone, and
/// of equals the first listed (`modelConfigPriority`, acpx #571 in 0.16.0). acpx 0.19.3
/// picks these the same way against the same options.
struct ModelOptionPriorityTests {
    private func option(_ id: String, category: String?, values: [String]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "name": .string(id), "type": .string("select"), "currentValue": .string(values[0]),
            "options": .array(values.map { .object(["value": .string($0), "name": .string($0)]) })
        ]
        if let category { fields["category"] = .string(category) }
        return .object(fields)
    }

    private func picked(_ options: [JSONValue]) -> String? {
        ModelSupport.modelState(fromConfigOptions: .array(options))?.configId
    }

    @Test func theModelsOwnOptionIsTakenBeforeAProviderSelector() {
        let provider = option("provider", category: "model", values: ["p1", "p2"])
        let model = option("model", category: "model", values: ["m1", "m2"])
        #expect(picked([provider, model]) == "model")
        #expect(ModelSupport.modelState(fromConfigOptions: .array([provider, model]))?.currentModelId == "m1")
    }

    @Test func anOptionInTheModelCategoryIsTakenBeforeOneOnlyNamedModel() {
        let named = option("model", category: nil, values: ["m1", "m2"])
        let fast = option("fast", category: "model", values: ["f1", "f2"])
        #expect(picked([named, fast]) == "fast")
        #expect(picked([named]) == "model")
    }

    @Test func ofEqualsTheFirstListedIsTaken() {
        let fast = option("fast", category: "model", values: ["f1"])
        let provider = option("provider", category: "model", values: ["p1"])
        #expect(picked([fast, provider]) == "fast")
        #expect(picked([provider, fast]) == "provider")
    }

    /// Only an option that parses as a model picker competes.
    @Test func anOptionThatIsNoModelPickerIsPassedOver() {
        var broken = option("model", category: "model", values: ["m1"])
        if case .object(var fields) = broken {
            fields["options"] = .string("oops")
            broken = .object(fields)
        }
        let provider = option("provider", category: "model", values: ["p1"])
        #expect(picked([broken, provider]) == "provider")
    }
}
