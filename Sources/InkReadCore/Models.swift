import Foundation

public struct Book: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var importedAt: Date
    public var pageCount: Int
    /// Zero-based PDF page index.
    public var currentPage: Int
    public var tags: [String]

    public init(id: UUID = UUID(), title: String, importedAt: Date = Date(), pageCount: Int,
                currentPage: Int = 0, tags: [String] = []) {
        self.id = id
        self.title = title
        self.importedAt = importedAt
        self.pageCount = pageCount
        self.currentPage = currentPage
        self.tags = tags
    }
}

/// PDF page coordinates, independent of the reader's current zoom and scrolling.
public struct PageRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SourceAnchor: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var pageIndex: Int
    public var pageLabel: String?
    public var rects: [PageRect]
    public var selectedText: String?
    /// Path relative to the library root, never an arbitrary filesystem path.
    public var imageRelativePath: String?
    public var surroundingText: String?

    public init(id: UUID = UUID(), documentID: UUID, pageIndex: Int, pageLabel: String? = nil,
                rects: [PageRect] = [], selectedText: String? = nil,
                imageRelativePath: String? = nil, surroundingText: String? = nil) {
        self.id = id
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.rects = rects
        self.selectedText = selectedText
        self.imageRelativePath = imageRelativePath
        self.surroundingText = surroundingText
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public enum Status: String, Codable, Sendable {
        case inProgress, completed, failed, interrupted
    }

    public var id: UUID
    public var role: Role
    public var body: String
    public var status: Status
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, body: String = "",
                status: Status = .completed, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.body = body
        self.status = status
        self.createdAt = createdAt
    }
}

public struct Discussion: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var title: String
    public var anchor: SourceAnchor?
    public var codexThreadID: String?
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), documentID: UUID, title: String = "新讨论",
                anchor: SourceAnchor? = nil, codexThreadID: String? = nil,
                messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.anchor = anchor
        self.codexThreadID = codexThreadID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var discussionID: UUID?
    public var title: String
    public var body: String
    public var anchors: [SourceAnchor]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), documentID: UUID, discussionID: UUID? = nil,
                title: String = "新笔记", body: String = "", anchors: [SourceAnchor] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.discussionID = discussionID
        self.title = title
        self.body = body
        self.anchors = anchors
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
