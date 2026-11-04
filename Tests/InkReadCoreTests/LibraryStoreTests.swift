import Foundation
import XCTest
@testable import InkReadCore

final class LibraryStoreTests: XCTestCase {
    private func makeFixture() throws -> (directory: URL, root: URL, pdf: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkReadCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("sample.pdf")
        try Data("%PDF-1.4\nfixture-\(UUID().uuidString)\n%%EOF\n".utf8).write(to: source)
        return (directory, directory.appendingPathComponent("library", isDirectory: true), source)
    }

    @MainActor
    func testLibrarySurvivesRestartWithSelectionConversationAndNote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        var book = try store.importPDF(from: fixture.pdf, title: "因子研究", pageCount: 12)
        book.currentPage = 4
        book.tags = ["量化", "待阅读"]
        try store.updateBook(book)
        let path = try store.saveImage(Data([137, 80, 78, 71]), for: book)
        let anchor = SourceAnchor(documentID: book.id, pageIndex: 4, pageLabel: "iv",
                                  rects: [PageRect(x: 12, y: 40, width: 200, height: 64)],
                                  selectedText: "为什么需要样本外验证？", imageRelativePath: path,
                                  surroundingText: "模型选择的上下文")
        let discussion = Discussion(documentID: book.id, title: "理解样本外验证", anchor: anchor,
                                    codexThreadID: "thread-fixture",
                                    messages: [ChatMessage(role: .user, body: "解释一下"),
                                               ChatMessage(role: .assistant, body: "避免过拟合。")])
        try store.upsert(discussion)
        let note = Note(documentID: book.id, discussionID: discussion.id, title: "结论",
                        body: "研究流程需要保留独立测试集。", anchors: [anchor])
        try store.upsert(note)

        let reopened = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.books.first?.id, book.id)
        XCTAssertEqual(reopened.books.first?.currentPage, 4)
        XCTAssertEqual(reopened.books.first?.tags, ["量化", "待阅读"])
        XCTAssertEqual(reopened.discussions.first?.codexThreadID, "thread-fixture")
        XCTAssertEqual(reopened.discussions.first?.messages.map(\.body), ["解释一下", "避免过拟合。"])
        XCTAssertEqual(reopened.notes.first?.discussionID, discussion.id)
        XCTAssertEqual(reopened.notes.first?.anchors, [anchor])
        XCTAssertEqual(try Data(contentsOf: reopened.pdfURL(for: book)), try Data(contentsOf: fixture.pdf))
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(relativePath: path)), Data([137, 80, 78, 71]))
    }

    @MainActor
    func testIdenticalContentsAreDeduplicatedAcrossPathsAndRestarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let first = try store.importPDF(from: fixture.pdf, title: "首次导入", pageCount: 5)
        let copiedSource = fixture.directory.appendingPathComponent("renamed.pdf")
        try FileManager.default.copyItem(at: fixture.pdf, to: copiedSource)
        let reopened = try LibraryStore(rootURL: fixture.root)
        let second = try reopened.importPDF(from: copiedSource, title: "另一个名字", pageCount: 5)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.books.first?.title, "首次导入")
    }

    @MainActor
    func testExportIncludesOriginalReferenceLinkedNoteAndBothConversationRoles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "统计学习", pageCount: 3)
        let anchor = SourceAnchor(documentID: book.id, pageIndex: 1, selectedText: "风险的偏差与方差")
        let discussion = Discussion(documentID: book.id, title: "误差分解", anchor: anchor,
                                    messages: [ChatMessage(role: .user, body: "如何理解？"),
                                               ChatMessage(role: .assistant, body: "分别考察偏差、方差和噪声。")])
        try store.upsert(discussion)
        try store.upsert(Note(documentID: book.id, discussionID: discussion.id, title: "复习卡片",
                              body: "模型复杂度影响偏差与方差。", anchors: [anchor]))
        let exportedURL = fixture.directory.appendingPathComponent("reading.md")
        try store.exportMarkdown(for: book, to: exportedURL)
        let markdown = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# 统计学习"))
        XCTAssertTrue(markdown.contains("复习卡片"))
        XCTAssertTrue(markdown.contains(discussion.id.uuidString))
        XCTAssertTrue(markdown.contains("#page=2"))
        XCTAssertTrue(markdown.contains("> 风险的偏差与方差"))
        XCTAssertTrue(markdown.contains("**我**"))
        XCTAssertTrue(markdown.contains("**Codex**"))
        XCTAssertTrue(markdown.contains("分别考察偏差、方差和噪声。"))
    }

    @MainActor
    func testCorruptManifestIsReportedAndNeverOverwritten() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        let damaged = Data("{broken-library".utf8)
        try damaged.write(to: manifestURL)
        XCTAssertThrowsError(try LibraryStore(rootURL: fixture.root))
        XCTAssertEqual(try Data(contentsOf: manifestURL), damaged)
    }

    @MainActor
    func testFailedCommitDoesNotPublishUnsavedNote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "持久化测试", pageCount: 1)
        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        // A directory at the destination forces an atomic-write failure without
        // depending on POSIX permissions (which differ for privileged test runners).
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.upsert(Note(documentID: book.id, body: "不能假装已保存")))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(store.books.count, 1)
    }

    @MainActor
    func testInvalidForeignKeysAndEscapingAssetPathDoNotCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "引用测试", pageCount: 1)
        XCTAssertThrowsError(try store.upsert(Note(documentID: book.id, discussionID: UUID())))
        let anchor = SourceAnchor(documentID: book.id, pageIndex: 0, imageRelativePath: "../../private.png")
        XCTAssertThrowsError(try store.upsert(Discussion(documentID: book.id, anchor: anchor)))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.discussions.isEmpty)
        XCTAssertTrue(store.assetURL(relativePath: "../../private.png").path.hasPrefix(fixture.root.path + "/"))
    }

    @MainActor
    func testRestartMarksUnfinishedResponsesInterruptedAndPreservesPartialText() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LibraryStore(rootURL: fixture.root)
        let book = try store.importPDF(from: fixture.pdf, title: "恢复测试", pageCount: 1)
        let discussion = Discussion(documentID: book.id, messages: [
            ChatMessage(role: .user, body: "解释这段内容"),
            ChatMessage(role: .assistant, body: "已经生成的片段", status: .inProgress),
            ChatMessage(role: .assistant, body: "", status: .inProgress)
        ])
        try store.upsert(discussion)

        let reopened = try LibraryStore(rootURL: fixture.root)
        let recovered = try XCTUnwrap(reopened.discussions.first)
        XCTAssertEqual(recovered.messages[0].status, .completed)
        XCTAssertEqual(recovered.messages[1].status, .interrupted)
        XCTAssertEqual(recovered.messages[1].body, "已经生成的片段")
        XCTAssertEqual(recovered.messages[2].status, .interrupted)
        XCTAssertFalse(recovered.messages[2].body.isEmpty)
        let reopenedAgain = try LibraryStore(rootURL: fixture.root)
        XCTAssertEqual(reopenedAgain.discussions.first?.messages[1].body, "已经生成的片段")
        XCTAssertEqual(reopenedAgain.discussions.first?.messages[1].status, .interrupted)
    }
}
