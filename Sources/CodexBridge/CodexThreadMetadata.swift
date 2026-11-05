import Foundation

/// Metadata only. Conversation turns, authentication, and rollout contents are
/// intentionally not exposed by the stored-thread audit used by InkRead.
public struct CodexStoredThread: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let originator: String?
    public let source: String?
    public let ephemeral: Bool
    public let path: String?

    private enum CodingKeys: String, CodingKey { case id, cwd, originator, source, ephemeral, path }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        cwd = try values.decode(String.self, forKey: .cwd)
        originator = try values.decodeIfPresent(String.self, forKey: .originator)
        // Source is an extensible protocol union. Structured sub-agent sources
        // are irrelevant to this audit, so retain only a known string value.
        source = try? values.decode(String.self, forKey: .source)
        ephemeral = try values.decode(Bool.self, forKey: .ephemeral)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        guard !id.isEmpty, cwd.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(forKey: .cwd, in: values, debugDescription: "Thread metadata has no identifier or absolute working directory")
        }
    }
}
