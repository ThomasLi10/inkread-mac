import Combine
import CryptoKit
import Foundation

public enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidLibrary(String)
    case missingBook(UUID)
    case invalidPDF
    case unsafeAssetPath

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "知识库格式版本 \(version) 暂不受支持。原有文件未被修改。"
        case .invalidLibrary(let detail): return "知识库数据异常：\(detail)。原有文件未被修改。"
        case .missingBook: return "找不到对应的 PDF 知识库。"
        case .invalidPDF: return "所选文件不是可导入的 PDF，或 PDF 没有可阅读的页面。"
        case .unsafeAssetPath: return "知识库附件路径无效。"
        }
    }
}

/// The manifest is the sole metadata authority. Every commit is an atomic file
/// replacement, and published state changes only after that replacement succeeds.
/// Each book has an isolated directory for the PDF, rendered selections and context.
@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var books: [Book]
    @Published public private(set) var discussions: [Discussion]
    @Published public private(set) var notes: [Note]
    public let rootURL: URL

    private struct Manifest: Codable {
        var schemaVersion: Int = 1
        var books: [Book] = []
        var discussions: [Discussion] = []
        var notes: [Note] = []
        /// UUID string -> SHA256 of the original imported PDF.
        var fingerprints: [String: String] = [:]
    }

    private var manifest: Manifest
    private let fileManager = FileManager.default
    private var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

    public init(rootURL: URL? = nil) throws {
        let base = try rootURL ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("InkRead", isDirectory: true)
        self.rootURL = base.standardizedFileURL

        let manifestURL = self.rootURL.appendingPathComponent("manifest.json")
        let loaded: Manifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                loaded = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            } catch {
                throw LibraryStoreError.invalidLibrary("manifest.json 无法读取（\(error.localizedDescription)）")
            }
            try Self.validate(loaded)
        } else {
            // Never silently reconstruct an empty library over existing book data.
            let booksURL = self.rootURL.appendingPathComponent("books", isDirectory: true)
            if FileManager.default.fileExists(atPath: booksURL.path),
               !(try FileManager.default.contentsOfDirectory(atPath: booksURL.path)).isEmpty {
                throw LibraryStoreError.invalidLibrary("发现书籍目录，但缺少 manifest.json")
            }
            loaded = Manifest()
        }
        manifest = loaded
        books = loaded.books
        discussions = loaded.discussions
        notes = loaded.notes
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("books", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A process restart cannot have a live response task. Preserve checkpointed
        // text but make unfinished messages visibly resumable rather than leaving
        // a permanent spinner. Persist the recovery once, atomically.
        var recovered = loaded
        var didRecover = false
        for discussionIndex in recovered.discussions.indices {
            for messageIndex in recovered.discussions[discussionIndex].messages.indices {
                guard recovered.discussions[discussionIndex].messages[messageIndex].status == .inProgress else { continue }
                recovered.discussions[discussionIndex].messages[messageIndex].status = .interrupted
                if recovered.discussions[discussionIndex].messages[messageIndex].body.isEmpty {
                    recovered.discussions[discussionIndex].messages[messageIndex].body = "上次生成因应用关闭而中断。"
                }
                didRecover = true
            }
        }
        if didRecover { try commit(recovered) }
    }

    @discardableResult
    public func importPDF(from sourceURL: URL, title: String, pageCount: Int) throws -> Book {
        guard pageCount > 0 else { throw LibraryStoreError.invalidPDF }
        let digest = try Self.pdfFingerprint(at: sourceURL)
        if let existing = books.first(where: { manifest.fingerprints[$0.id.uuidString] == digest }) {
            guard fileManager.fileExists(atPath: pdfURL(for: existing).path) else {
                throw LibraryStoreError.invalidLibrary("已导入书籍的原始 PDF 丢失，请恢复文件后重试")
            }
            return existing
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = Book(title: trimmedTitle.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : trimmedTitle,
                        pageCount: pageCount)
        let directory = bookDirectory(for: book.id)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspaceURL(for: book), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory.appendingPathComponent("assets", isDirectory: true),
                                            withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: pdfURL(for: book))
            guard try Self.pdfFingerprint(at: pdfURL(for: book)) == digest else {
                throw LibraryStoreError.invalidLibrary("导入过程中原 PDF 发生变化，请重新导入")
            }

            var next = manifest
            next.books.append(book)
            next.fingerprints[book.id.uuidString] = digest
            try commit(next)
        } catch {
            // This directory belongs to the new UUID and cannot contain existing data.
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return book
    }

    public func pdfURL(for book: Book) -> URL {
        bookDirectory(for: book.id).appendingPathComponent("source.pdf")
    }

    /// Codex's working directory is the entire per-book directory, so source.pdf
    /// and assets are available beside context files the app chooses to generate.
    public func workspaceURL(for book: Book) -> URL {
        bookDirectory(for: book.id)
    }

    @discardableResult
    public func saveImage(_ data: Data, for book: Book) throws -> String {
        guard books.contains(where: { $0.id == book.id }) else { throw LibraryStoreError.missingBook(book.id) }
        let relativePath = "books/\(book.id.uuidString)/assets/\(UUID().uuidString).png"
        let url = try checkedAssetURL(relativePath: relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return relativePath
    }

    public func assetURL(relativePath: String) -> URL {
        // The nonthrowing lookup never resolves an untrusted path outside the library.
        (try? checkedAssetURL(relativePath: relativePath))
            ?? rootURL.appendingPathComponent("__invalid_asset__")
    }

    public func upsert(_ discussion: Discussion) throws {
        var next = manifest
        if let index = next.discussions.firstIndex(where: { $0.id == discussion.id }) {
            next.discussions[index] = discussion
        } else {
            next.discussions.append(discussion)
        }
        try commit(next)
    }

    public func upsert(_ note: Note) throws {
        var next = manifest
        if let index = next.notes.firstIndex(where: { $0.id == note.id }) {
            next.notes[index] = note
        } else {
            next.notes.append(note)
        }
        try commit(next)
    }

    public func updateBook(_ book: Book) throws {
        guard let index = manifest.books.firstIndex(where: { $0.id == book.id }) else {
            throw LibraryStoreError.missingBook(book.id)
        }
        var next = manifest
        next.books[index] = book
        try commit(next)
    }

    public func deleteNote(id: UUID) throws {
        guard manifest.notes.contains(where: { $0.id == id }) else { return }
        var next = manifest
        next.notes.removeAll { $0.id == id }
        try commit(next)
    }

    public func exportMarkdown(for book: Book, to url: URL) throws {
        guard let currentBook = books.first(where: { $0.id == book.id }) else {
            throw LibraryStoreError.missingBook(book.id)
        }
        let dateFormatter = ISO8601DateFormatter()
        let bookNotes = notes.filter { $0.documentID == book.id }.sorted { $0.createdAt < $1.createdAt }
        let bookDiscussions = discussions.filter { $0.documentID == book.id }.sorted { $0.createdAt < $1.createdAt }
        var lines = ["# \(Self.heading(currentBook.title))", "",
                     "- 标签：\(currentBook.tags.joined(separator: "、"))",
                     "- 导入时间：\(dateFormatter.string(from: currentBook.importedAt))",
                     "- [PDF 原文](\(pdfURL(for: currentBook).absoluteString))", "",
                     "## 阅读笔记", ""]
        for note in bookNotes {
            lines += ["### \(Self.heading(note.title))", "", note.body, ""]
            if let discussionID = note.discussionID {
                lines += ["关联讨论：\(discussionID.uuidString)", ""]
            }
            for anchor in note.anchors { lines += markdown(for: anchor) }
        }
        if bookNotes.isEmpty { lines += ["暂无笔记。", ""] }
        lines += ["## 讨论记录", ""]
        for discussion in bookDiscussions {
            lines += ["### \(Self.heading(discussion.title))", "", "讨论 ID：\(discussion.id.uuidString)", ""]
            if let anchor = discussion.anchor { lines += markdown(for: anchor) }
            for message in discussion.messages {
                let role = message.role == .user ? "我" : "Codex"
                let state = message.status == .completed ? "" : "（\(message.status.rawValue)）"
                lines += ["**\(role)\(state)**", "", message.body, ""]
            }
        }
        if bookDiscussions.isEmpty { lines += ["暂无讨论。", ""] }
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    private func markdown(for anchor: SourceAnchor) -> [String] {
        guard let book = books.first(where: { $0.id == anchor.documentID }) else { return [] }
        let label = anchor.pageLabel ?? String(anchor.pageIndex + 1)
        var lines = ["来源：[\(Self.heading(book.title)) · 第 \(label) 页](\(pdfURL(for: book).absoluteString)#page=\(anchor.pageIndex + 1))", ""]
        if let text = anchor.selectedText, !text.isEmpty {
            lines += text.components(separatedBy: .newlines).map { "> \($0)" }
            lines.append("")
        }
        if let path = anchor.imageRelativePath {
            lines += ["![PDF 选区](\(assetURL(relativePath: path).absoluteString))", ""]
        }
        return lines
    }

    private func bookDirectory(for id: UUID) -> URL {
        rootURL.appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func checkedAssetURL(relativePath: String) throws -> URL {
        guard Self.isSafeRelativePath(relativePath) else { throw LibraryStoreError.unsafeAssetPath }
        let base = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = rootURL.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/") else { throw LibraryStoreError.unsafeAssetPath }
        return resolved
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private func commit(_ next: Manifest) throws {
        try Self.validate(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(next)
        try data.write(to: manifestURL, options: .atomic)
        manifest = next
        books = next.books
        discussions = next.discussions
        notes = next.notes
    }

    private static func validate(_ data: Manifest) throws {
        guard data.schemaVersion == 1 else { throw LibraryStoreError.unsupportedSchema(data.schemaVersion) }
        let bookIDs = Set(data.books.map(\.id))
        let discussionIDs = Set(data.discussions.map(\.id))
        guard bookIDs.count == data.books.count,
              discussionIDs.count == data.discussions.count,
              Set(data.notes.map(\.id)).count == data.notes.count else {
            throw LibraryStoreError.invalidLibrary("条目 ID 重复")
        }
        for book in data.books {
            guard book.pageCount > 0, book.currentPage >= 0, book.currentPage < book.pageCount else {
                throw LibraryStoreError.invalidLibrary("书籍页码超出范围")
            }
        }
        func validateAnchor(_ anchor: SourceAnchor) throws {
            guard let book = data.books.first(where: { $0.id == anchor.documentID }),
                  anchor.pageIndex >= 0, anchor.pageIndex < book.pageCount,
                  anchor.rects.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite
                      && $0.height.isFinite && $0.width >= 0 && $0.height >= 0 }) else {
                throw LibraryStoreError.invalidLibrary("原文引用的文档、页码或坐标无效")
            }
            if let path = anchor.imageRelativePath, !isSafeRelativePath(path) {
                throw LibraryStoreError.unsafeAssetPath
            }
        }
        for discussion in data.discussions {
            guard bookIDs.contains(discussion.documentID) else {
                throw LibraryStoreError.missingBook(discussion.documentID)
            }
            guard Set(discussion.messages.map(\.id)).count == discussion.messages.count else {
                throw LibraryStoreError.invalidLibrary("讨论中的消息 ID 重复")
            }
            if let anchor = discussion.anchor {
                guard anchor.documentID == discussion.documentID else {
                    throw LibraryStoreError.invalidLibrary("讨论的原文引用不属于该书籍")
                }
                try validateAnchor(anchor)
            }
        }
        for note in data.notes {
            guard bookIDs.contains(note.documentID) else { throw LibraryStoreError.missingBook(note.documentID) }
            if let id = note.discussionID, !discussionIDs.contains(id) {
                throw LibraryStoreError.invalidLibrary("笔记关联的讨论不存在")
            }
            // A note may deliberately cite another book, enabling cross-book context.
            for anchor in note.anchors { try validateAnchor(anchor) }
        }
    }

    private static func pdfFingerprint(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 1024) ?? Data()
        guard prefix.range(of: Data("%PDF-".utf8)) != nil else { throw LibraryStoreError.invalidPDF }
        var hasher = SHA256()
        hasher.update(data: prefix)
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func heading(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
