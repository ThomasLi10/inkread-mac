import Foundation

public enum AnnotationColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, purple

    public var title: String {
        switch self {
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .pink: return "粉色"
        case .purple: return "紫色"
        }
    }

    public var hex: String {
        switch self {
        case .yellow: return "F8CE46"
        case .green: return "7BCB9A"
        case .blue: return "80B7F2"
        case .pink: return "EAA2BC"
        case .purple: return "B7A0DF"
        }
    }
}

public struct ReadingAnnotation: Identifiable, Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        case highlight, underline, box
        public var title: String {
            switch self {
            case .highlight: return "高亮"
            case .underline: return "下划线"
            case .box: return "方框"
            }
        }
    }

    public var id: UUID
    public var documentID: UUID
    public var anchor: SourceAnchor
    public var style: Style
    public var color: AnnotationColor
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), documentID: UUID, anchor: SourceAnchor,
                style: Style = .highlight, color: AnnotationColor = .yellow, body: String = "",
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.documentID = documentID; self.anchor = anchor
        self.style = style; self.color = color; self.body = body
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum QuestionStatus: String, Codable, CaseIterable, Sendable {
    case open, verify, resolved
    public var title: String {
        switch self {
        case .open: return "待理解"
        case .verify: return "待核实"
        case .resolved: return "已解决"
        }
    }
}

public struct ReadingQuestion: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var discussionID: UUID?
    public var title: String
    public var detail: String
    public var status: QuestionStatus
    public var anchor: SourceAnchor?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), documentID: UUID, discussionID: UUID? = nil,
                title: String, detail: String = "", status: QuestionStatus = .open,
                anchor: SourceAnchor? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.documentID = documentID; self.discussionID = discussionID
        self.title = title; self.detail = detail; self.status = status; self.anchor = anchor
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct GlossaryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var term: String
    public var meaning: String
    public var scope: String
    public var anchors: [SourceAnchor]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), documentID: UUID, term: String, meaning: String = "",
                scope: String = "", anchors: [SourceAnchor] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.documentID = documentID; self.term = term
        self.meaning = meaning; self.scope = scope; self.anchors = anchors
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ContextItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var title: String
    public var body: String
    public var anchor: SourceAnchor?
    public var noteID: UUID?
    public var discussionID: UUID?
    public var sourceAnchors: [SourceAnchor]?

    /// Keep the legacy primary source first, then retain every additional source
    /// once by stable anchor identity. Stored message values remain snapshots.
    public var anchors: [SourceAnchor] {
        var seen = Set<UUID>()
        return ((anchor.map { [$0] } ?? []) + (sourceAnchors ?? []))
            .filter { seen.insert($0.id).inserted }
    }

    public init(id: UUID = UUID(), documentID: UUID, title: String, body: String = "",
                anchor: SourceAnchor? = nil, noteID: UUID? = nil, discussionID: UUID? = nil,
                sourceAnchors: [SourceAnchor]? = nil) {
        self.id = id; self.documentID = documentID; self.title = title; self.body = body
        self.anchor = anchor; self.noteID = noteID; self.discussionID = discussionID
        self.sourceAnchors = sourceAnchors
    }
}

public struct BookWorkspace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { documentID }
    public var documentID: UUID
    public var contextItems: [ContextItem]
    public var pinnedAnchor: SourceAnchor?

    public init(documentID: UUID, contextItems: [ContextItem] = [], pinnedAnchor: SourceAnchor? = nil) {
        self.documentID = documentID; self.contextItems = contextItems; self.pinnedAnchor = pinnedAnchor
    }
}
