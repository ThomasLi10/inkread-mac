import Foundation
import XCTest
@testable import InkReadCore

final class ReadingStoreTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture() throws -> (directory: URL, root: URL, pdf: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkReadReadingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("sample.pdf")
        try Data("%PDF-1.4\nreading-fixture-\(UUID().uuidString)\n%%EOF\n".utf8).write(to: pdf)
        return (directory, directory.appendingPathComponent("library", isDirectory: true), pdf)
    }

    /// Reproduce exactly the old manifest shape: none of the new collection keys
    /// or message context fields exist. Preserve these bytes to verify the backup.
    private func writeSchemaOne(at root: URL) throws -> Data {
        let url = root.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = 1
        for key in ["annotations", "questions", "terms", "workspaces"] { object.removeValue(forKey: key) }
        var discussions = object["discussions"] as? [[String: Any]] ?? []
        for index in discussions.indices {
            var messages = discussions[index]["messages"] as? [[String: Any]] ?? []
            for messageIndex in messages.indices { messages[messageIndex].removeValue(forKey: "contextItems") }
            discussions[index]["messages"] = messages
        }
        object["discussions"] = discussions
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: url, options: .atomic)
        return bytes
    }

    @MainActor
    func testSchemaOneLoadsLosslesslyAndFirstWritePreservesExactBackupOnce() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try LibraryStore(rootURL: fixture.root)
        let book = try original.importPDF(from: fixture.pdf, title: "旧书库", pageCount: 3)
        let discussion = Discussion(documentID: book.id, title: "旧讨论", codexThreadID: "legacy-thread",
                                    messages: [ChatMessage(role: .user, body: "旧问题"), ChatMessage(role: .assistant, body: "旧回答")])
        try original.upsert(discussion)
        let note = Note(documentID: book.id, discussionID: discussion.id, title: "旧笔记", body: "保留原文")
        try original.upsert(note)
        let legacy = try writeSchemaOne(at: fixture.root)
        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        let backupURL = fixture.root.appendingPathComponent("manifest-v1-backup.json")

        let migrated = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(migrated.books.first?.id, book.id)
        XCTAssertEqual(migrated.discussions.first?.codexThreadID, "legacy-thread")
        XCTAssertEqual(migrated.discussions.first?.messages.map(\.body), ["旧问题", "旧回答"])
        XCTAssertNil(migrated.discussions.first?.messages.first?.contextItems)
        XCTAssertEqual(migrated.notes.first?.body, "保留原文")
        XCTAssertTrue(migrated.annotations.isEmpty && migrated.questions.isEmpty && migrated.terms.isEmpty && migrated.workspaces.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifestURL), legacy, "Read-only loading must not silently rewrite the manifest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        var changed = book
        changed.title = "迁移后的书名"
        try migrated.updateBook(changed)
        XCTAssertEqual(try Data(contentsOf: backupURL), legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(object["annotations"])
        try migrated.upsert(ReadingQuestion(documentID: book.id, title: "新的疑问"))
        XCTAssertEqual(try Data(contentsOf: backupURL), legacy, "Later saves must not replace the original v1 backup")
        let reopened = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(reopened.notes.first?.id, note.id)
        XCTAssertEqual(reopened.discussions.first?.messages.last?.body, "旧回答")
        XCTAssertEqual(reopened.questions.count, 1)
    }

    @MainActor
    func testReadingCollectionsWorkspaceAndMarkdownSurviveRestart() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "阅读工作台", pageCount: 4)
        let anchor = SourceAnchor(documentID: book.id, pageIndex: 2, selectedText: "样本外验证")
        let discussion = Discussion(documentID: book.id, title: "验证讨论", anchor: anchor)
        try store.upsert(discussion)
        let note = Note(documentID: book.id, title: "验证笔记", body: "独立测试集")
        try store.upsert(note)
        let item = ContextItem(documentID: book.id, title: "上下文证据", body: "冻结的笔记摘录",
                               anchor: anchor, noteID: note.id, discussionID: discussion.id)
        let annotation = ReadingAnnotation(documentID: book.id, anchor: anchor, style: .underline,
                                            color: .purple, body: "重要前提", createdAt: timestamp, updatedAt: timestamp)
        let question = ReadingQuestion(documentID: book.id, discussionID: discussion.id, title: "是否数据泄露？",
                                       detail: "核对时间范围", status: .verify, anchor: anchor,
                                       createdAt: timestamp, updatedAt: timestamp)
        let term = GlossaryEntry(documentID: book.id, term: "OOS", meaning: "样本外", scope: "模型验证",
                                 anchors: [anchor], createdAt: timestamp, updatedAt: timestamp)
        try store.upsert(annotation)
        try store.upsert(question)
        try store.upsert(term)
        try store.upsert(BookWorkspace(documentID: book.id, contextItems: [item], pinnedAnchor: anchor))
        var submitted = discussion
        submitted.messages = [ChatMessage(role: .user, body: "一起分析", contextItems: [item])]
        try store.upsert(submitted)

        let reopened = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(reopened.annotations, [annotation])
        XCTAssertEqual(reopened.questions, [question])
        XCTAssertEqual(reopened.terms, [term])
        XCTAssertEqual(reopened.workspace(for: book.id).contextItems, [item])
        XCTAssertEqual(reopened.workspace(for: book.id).pinnedAnchor, anchor)
        XCTAssertTrue(reopened.workspace(for: UUID()).contextItems.isEmpty)
        let markdownURL = fixture.directory.appendingPathComponent("reading.md")
        try reopened.exportMarkdown(for: book, to: markdownURL)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        for expected in ["## 阅读批注", "下划线 · 紫色", "重要前提", "[待核实] 是否数据泄露？", "## 术语表", "OOS", "模型验证", "上下文快照", "冻结的笔记摘录", "#page=3"] {
            XCTAssertTrue(markdown.contains(expected), "Missing exported content: \(expected)")
        }
        try reopened.deleteAnnotation(id: annotation.id)
        try reopened.deleteQuestion(id: question.id)
        try reopened.deleteTerm(id: term.id)
        let afterDelete = try LibraryStore(rootURL: fixture.root)
        XCTAssertTrue(afterDelete.annotations.isEmpty && afterDelete.questions.isEmpty && afterDelete.terms.isEmpty)
    }

    @MainActor
    func testSubmittedContextIsAValueSnapshotIndependentOfBasketAndSourceNote() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "上下文快照", pageCount: 2)
        var note = Note(documentID: book.id, title: "来源笔记", body: "第一版原意")
        try store.upsert(note)
        let snapshot = ContextItem(documentID: book.id, title: "第一次提交", body: note.body, noteID: note.id)
        var workspace = BookWorkspace(documentID: book.id, contextItems: [snapshot])
        try store.upsert(workspace)
        let discussion = Discussion(documentID: book.id, messages: [ChatMessage(role: .user, body: "请解释", contextItems: workspace.contextItems)])
        try store.upsert(discussion)
        workspace.contextItems[0].body = "后来修改的篮子内容"
        try store.upsert(workspace)
        note.body = "后来修改的原笔记"
        try store.upsert(note)
        XCTAssertEqual(store.discussions.first?.messages.first?.contextItems, [snapshot])
        try store.deleteNote(id: note.id)
        XCTAssertNil(store.workspace(for: book.id).contextItems.first?.noteID)
        XCTAssertEqual(store.workspace(for: book.id).contextItems.first?.body, "后来修改的篮子内容")
        let reopened = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(reopened.discussions.first?.messages.first?.contextItems, [snapshot], "Historical provenance is a soft link; deleting a note cannot rewrite a submitted message")
    }

    @MainActor
    func testInvalidReadingReferencesAndExternalAssetsNeverPublish() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "边界检查", pageCount: 2)
        let good = SourceAnchor(documentID: book.id, pageIndex: 0)
        XCTAssertThrowsError(try store.upsert(ReadingAnnotation(documentID: UUID(), anchor: good)))
        XCTAssertThrowsError(try store.upsert(ReadingQuestion(documentID: book.id, discussionID: UUID(), title: "无效讨论")))
        XCTAssertThrowsError(try store.upsert(GlossaryEntry(documentID: book.id, term: "错误页码",
                                                          anchors: [SourceAnchor(documentID: book.id, pageIndex: 2)])))
        XCTAssertThrowsError(try store.upsert(BookWorkspace(documentID: book.id,
                                                            contextItems: [ContextItem(documentID: book.id, title: "无效笔记", noteID: UUID())])))
        XCTAssertThrowsError(try store.upsert(Discussion(documentID: book.id,
                                                        messages: [ChatMessage(role: .user, contextItems: [ContextItem(documentID: UUID(), title: "无效书籍")])])))
        XCTAssertThrowsError(try store.upsert(Discussion(documentID: book.id,
                                                        messages: [ChatMessage(role: .user, contextItems: [ContextItem(documentID: book.id, title: "无效来源", noteID: UUID())])])))
        for path in ["/private/outside.png", "../outside.png", "file:///private/outside.png"] {
            var anchor = good
            anchor.imageRelativePath = path
            XCTAssertThrowsError(try store.upsert(ReadingAnnotation(documentID: book.id, anchor: anchor)))
        }
        let external = fixture.directory.appendingPathComponent("outside.png")
        try Data([0]).write(to: external)
        let relative = "books/\(book.id.uuidString)/assets/escape.png"
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(relative), withDestinationURL: external)
        var symlinkAnchor = good
        symlinkAnchor.imageRelativePath = relative
        XCTAssertThrowsError(try store.upsert(BookWorkspace(documentID: book.id, pinnedAnchor: symlinkAnchor)))
        XCTAssertTrue(store.annotations.isEmpty && store.questions.isEmpty && store.terms.isEmpty && store.workspaces.isEmpty && store.discussions.isEmpty)
    }

    @MainActor
    func testFailedAtomicWriteDoesNotPublishAnyNewReadingCollection() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "原子提交", pageCount: 1)
        let anchor = SourceAnchor(documentID: book.id, pageIndex: 0)
        let manifest = fixture.root.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.upsert(ReadingAnnotation(documentID: book.id, anchor: anchor)))
        XCTAssertThrowsError(try store.upsert(ReadingQuestion(documentID: book.id, title: "未保存的疑问")))
        XCTAssertThrowsError(try store.upsert(GlossaryEntry(documentID: book.id, term: "未保存的术语")))
        XCTAssertThrowsError(try store.upsert(BookWorkspace(documentID: book.id, pinnedAnchor: anchor)))
        XCTAssertTrue(store.annotations.isEmpty && store.questions.isEmpty && store.terms.isEmpty && store.workspaces.isEmpty)
    }

    @MainActor
    func testMigrationBackupFailureLeavesSchemaOneAndPublishedStateUnchanged() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try LibraryStore(rootURL: fixture.root)
        let book = try original.importPDF(from: fixture.pdf, title: "迁移失败", pageCount: 1)
        let bytes = try writeSchemaOne(at: fixture.root)
        let store = try LibraryStore(rootURL: fixture.root)
        let backup = fixture.root.appendingPathComponent("manifest-v1-backup.json")
        // Invalid mutations must not create a migration backup.
        XCTAssertThrowsError(try store.upsert(ReadingQuestion(documentID: UUID(), title: "无效引用")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.upsert(ReadingQuestion(documentID: book.id, title: "不能覆盖旧库")))
        XCTAssertTrue(store.questions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("manifest.json")), bytes)
    }

    @MainActor
    func testFutureSchemaIsRejectedWithoutWritingOrMakingBackup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let bytes = Data("{\"schemaVersion\":99}".utf8)
        let url = fixture.root.appendingPathComponent("manifest.json")
        try bytes.write(to: url)
        XCTAssertThrowsError(try LibraryStore(rootURL: fixture.root)) { error in
            guard case LibraryStoreError.unsupportedSchema(99) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("manifest-v1-backup.json").path))
    }

    @MainActor
    func testMultipleContextSourcesPersistExportAndRejectEveryInvalidExtraSource() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "多来源材料", pageCount: 4)
        let primary = SourceAnchor(documentID: book.id, pageIndex: 0, selectedText: "第一段证据")
        let imagePath = try store.saveImage(Data([137, 80, 78, 71]), for: book)
        let additional = SourceAnchor(documentID: book.id, pageIndex: 2, selectedText: "第三页图表证据", imageRelativePath: imagePath)
        let item = ContextItem(documentID: book.id, title: "两处来源", body: "结合两处材料的结论",
                               anchor: primary, sourceAnchors: [primary, additional, additional])
        XCTAssertEqual(item.anchors, [primary, additional], "Legacy source comes first; repeated stable IDs appear once")
        try store.upsert(BookWorkspace(documentID: book.id, contextItems: [item]))
        let discussion = Discussion(documentID: book.id, messages: [ChatMessage(role: .user, body: "综合解释", contextItems: [item])])
        try store.upsert(discussion)

        let reopened = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(reopened.workspace(for: book.id).contextItems.first?.anchors, [primary, additional])
        XCTAssertEqual(reopened.discussions.first?.messages.first?.contextItems, [item])
        let exportedURL = fixture.directory.appendingPathComponent("multi-source.md")
        try reopened.exportMarkdown(for: book, to: exportedURL)
        let markdown = try String(contentsOf: exportedURL, encoding: .utf8)
        for expected in ["第一段证据", "第三页图表证据", "#page=1", "#page=3", URL(fileURLWithPath: imagePath).lastPathComponent] {
            XCTAssertTrue(markdown.contains(expected), "Missing context source in export: \(expected)")
        }

        var onlyAdditional = item
        onlyAdditional.anchor = nil
        onlyAdditional.sourceAnchors = [additional]
        try reopened.upsert(BookWorkspace(documentID: book.id, contextItems: [onlyAdditional]))
        XCTAssertEqual(reopened.workspace(for: book.id).contextItems.first?.anchors, [additional])
        XCTAssertEqual(reopened.discussions.first?.messages.first?.contextItems, [item], "Editing the basket cannot change multi-source history")

        var badPage = additional
        badPage.pageIndex = 4
        var wrongOwner = additional
        wrongOwner.documentID = UUID()
        var outside = additional
        outside.imageRelativePath = "../outside.png"
        var conflictingPrimary = primary
        conflictingPrimary.imageRelativePath = "/private/outside.png"
        let external = fixture.directory.appendingPathComponent("outside.png")
        try Data([0]).write(to: external)
        let symlinkPath = "books/\(book.id.uuidString)/assets/extra-escape.png"
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(symlinkPath), withDestinationURL: external)
        var symlinkSource = additional
        symlinkSource.imageRelativePath = symlinkPath
        for source in [badPage, wrongOwner, outside, conflictingPrimary, symlinkSource] {
            var invalid = item
            invalid.sourceAnchors = [source]
            XCTAssertThrowsError(try reopened.upsert(BookWorkspace(documentID: book.id, contextItems: [invalid])))
            var invalidDiscussion = discussion
            invalidDiscussion.messages[0].contextItems = [invalid]
            XCTAssertThrowsError(try reopened.upsert(invalidDiscussion))
        }
        XCTAssertEqual(reopened.workspace(for: book.id).contextItems, [onlyAdditional])
        XCTAssertEqual(reopened.discussions.first?.messages.first?.contextItems, [item])
    }

    @MainActor
    func testInterruptedLegacyMessageRecoveryBacksUpBeforeMigration() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try LibraryStore(rootURL: fixture.root)
        let book = try original.importPDF(from: fixture.pdf, title: "中断迁移", pageCount: 1)
        try original.upsert(Discussion(documentID: book.id, messages: [ChatMessage(role: .assistant, body: "已生成片段", status: .inProgress)]))
        let bytes = try writeSchemaOne(at: fixture.root)
        let recovered = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(recovered.discussions.first?.messages.first?.body, "已生成片段")
        XCTAssertEqual(recovered.discussions.first?.messages.first?.status, .interrupted)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("manifest-v1-backup.json")), bytes)
    }
}
