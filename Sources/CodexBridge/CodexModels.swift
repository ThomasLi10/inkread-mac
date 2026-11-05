import Foundation

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Values come from this user's CLI catalog. They deliberately remain strings:
/// model providers can advertise new effort levels without an InkRead release.
public struct CodexReasoningEffort: Codable, Equatable, Identifiable, Sendable {
    public let reasoningEffort: String
    public let description: String
    public var id: String { reasoningEffort }

    public init(reasoningEffort: String, description: String) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

public struct CodexModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let model: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let hidden: Bool
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [CodexReasoningEffort]
    public let inputModalities: [String]
    public var supportsImages: Bool { inputModalities.contains("image") }

    public init(id: String, model: String, displayName: String, description: String, isDefault: Bool,
                hidden: Bool = false, defaultReasoningEffort: String,
                supportedReasoningEfforts: [CodexReasoningEffort], inputModalities: [String] = ["text", "image"]) {
        self.id = id; self.model = model; self.displayName = displayName; self.description = description
        self.isDefault = isDefault; self.hidden = hidden; self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts; self.inputModalities = inputModalities
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, displayName, description, isDefault, hidden, defaultReasoningEffort, supportedReasoningEfforts, inputModalities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        model = try values.decode(String.self, forKey: .model)
        displayName = try values.decode(String.self, forKey: .displayName)
        description = try values.decode(String.self, forKey: .description)
        isDefault = try values.decode(Bool.self, forKey: .isDefault)
        hidden = try values.decode(Bool.self, forKey: .hidden)
        defaultReasoningEffort = try values.decode(String.self, forKey: .defaultReasoningEffort)
        supportedReasoningEfforts = try values.decode([CodexReasoningEffort].self, forKey: .supportedReasoningEfforts)
        inputModalities = try values.decodeIfPresent([String].self, forKey: .inputModalities) ?? ["text", "image"]
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !defaultReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              supportedReasoningEfforts.allSatisfy({ !$0.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorruptedError(forKey: .model, in: values, debugDescription: "Model catalog contains an empty identifier or effort")
        }
    }
}
