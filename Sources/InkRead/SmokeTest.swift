import AppKit
import CoreText
import Foundation
import PDFKit
import InkReadCore
import CodexBridge

/// Opt-in live integration test. It uses the real app model and real Codex,
/// but only a newly created synthetic PDF inside an explicitly isolated library.
@MainActor
enum SmokeTest {
    private static var running = false

    private struct Step: Encodable {
        var name: String
        var status = "running"
        var startedAt = Date()
        var durationSeconds: Double?
        var details: [String: String] = [:]
    }

    private struct Report: Encodable {
        var schemaVersion = 1
        var status = "running"
        var mode = "live-app-model-and-codex"
        var startedAt = Date()
        var finishedAt: Date?
        var libraryRoot: String?
        var sourcePDF: String?
        var markdownExport: String?
        var currentStep = "isolation"
        var error: String?
        var steps: [Step] = []
    }

    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ detail: String) { errorDescription = detail }
    }

    static func run(model: AppModel) async {
        guard !running else { return }
        running = true
        var report = Report()
        let environment = ProcessInfo.processInfo.environment
        let rootString = environment["INKREAD_LIBRARY_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitReport = environment["INKREAD_SMOKE_REPORT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A default report is created only after the library passes isolation
        // checks. A rejected library root must not receive even a report file.
        var reportURL = explicitReport.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let oldLastBookID = UserDefaults.standard.object(forKey: "lastBookID")
        let oldModel = UserDefaults.standard.object(forKey: "inkreadCodexModel")
        let oldEffort = UserDefaults.standard.object(forKey: "inkreadCodexEffort")
        let languageChecks = environment["INKREAD_SMOKE_LANGUAGE"] == "1"
        let deadline = Date().addingTimeInterval(languageChecks ? 300 : 180)
        defer {
            for (key, original) in [("inkreadCodexModel", oldModel), ("inkreadCodexEffort", oldEffort)] {
                if let original { UserDefaults.standard.set(original, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        do {
            begin("isolation", report: &report, at: reportURL)
            guard let rootString, !rootString.isEmpty, rootString.hasPrefix("/") else {
                throw Failure("INKREAD_LIBRARY_ROOT must explicitly identify an isolated absolute test-library path. No test action was performed.")
            }
            let root = URL(fileURLWithPath: rootString, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let normalRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("InkRead", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let expectedRootPath = canonicalPath(root)
            let normalRootPath = normalRoot.map(canonicalPath)
            try require(expectedRootPath != "/" && expectedRootPath != canonicalPath(URL(fileURLWithPath: NSHomeDirectory())) && expectedRootPath != normalRootPath,
                        "Refusing to use a real/default library or a filesystem root for a smoke test.")
            guard let store = model.store else { throw Failure(model.errorMessage ?? "AppModel did not initialize its library.") }
            let actualRootPath = canonicalPath(store.rootURL)
            try require(actualRootPath == expectedRootPath,
                        "AppModel's actual library does not match INKREAD_LIBRARY_ROOT. Actual: \(actualRootPath); expected: \(expectedRootPath).")
            try require(store.books.isEmpty && store.discussions.isEmpty && store.notes.isEmpty,
                        "The test library must be empty. Existing knowledge-library data will not be used or replaced.")
            if reportURL == nil { reportURL = root.appendingPathComponent("smoke-report.json") }
            report.libraryRoot = root.path
            pass(["root": root.path, "initialBooks": "0", "initialDiscussions": "0", "initialNotes": "0"],
                 report: &report, at: reportURL)

            begin("generate-synthetic-two-page-pdf", report: &report, at: reportURL)
            let source = root.appendingPathComponent("synthetic-reading-\(UUID().uuidString).pdf")
            try makePDF(at: source)
            guard let sourcePDF = PDFDocument(url: source), sourcePDF.pageCount == 2 else {
                throw Failure("The generated fixture is not a readable two-page PDF.")
            }
            report.sourcePDF = source.path
            pass(["pageCount": "2", "content": "Self-created English prose and a bar chart: A=10, B=20, C=30."],
                 report: &report, at: reportURL)

            begin("app-import-and-reading-context", report: &report, at: reportURL)
            model.errorMessage = nil
            model.importPDFs([source])
            try require(model.isImporting, "AppModel.importPDFs did not begin an import.")
            try await wait(until: { !model.isImporting }, deadline: deadline, label: "PDF import")
            guard let book = model.selectedBook, store.books.count == 1, book.pageCount == 2 else {
                throw Failure(model.errorMessage ?? "The real importer did not create exactly one two-page book.")
            }
            let workspace = store.workspaceURL(for: book)
            for path in ["source.pdf", "BOOK.md", "pages/page-0001.txt", "pages/page-0002.txt"] {
                try require(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path),
                            "Import did not produce required context file: \(path)")
            }
            guard let importedPDF = PDFDocument(url: store.pdfURL(for: book)), let textPage = importedPDF.page(at: 0) else {
                throw Failure("The importer did not retain a readable source PDF.")
            }
            pass(["bookID": book.id.uuidString, "workspace": workspace.path, "contextFiles": "source.pdf, BOOK.md, both page text files"],
                 report: &report, at: reportURL)

            if languageChecks {
                begin("live-model-list-and-explicit-selection", report: &report, at: reportURL)
                model.refreshCodexModels()
                try await wait(until: { !model.isLoadingModels }, deadline: deadline, label: "available Codex models")
                guard let descriptor = model.availableModels.first(where: { $0.isDefault }) ?? model.availableModels.first else {
                    throw Failure(model.modelLoadingError ?? "Codex returned no selectable models.")
                }
                let effort = descriptor.supportedReasoningEfforts.first(where: { $0.reasoningEffort == "low" })?.reasoningEffort
                    ?? descriptor.supportedReasoningEfforts.first(where: { $0.reasoningEffort == descriptor.defaultReasoningEffort })?.reasoningEffort
                    ?? descriptor.supportedReasoningEfforts.first?.reasoningEffort
                guard let effort else { throw Failure("The selected model returned no supported reasoning efforts.") }
                model.selectCodexModel(descriptor.model)
                model.selectCodexEffort(effort)
                try require(model.selectedCodexModel == descriptor.model && model.selectedCodexEffort == effort,
                            "The app did not retain the explicitly selected model and effort.")
                pass(["modelCount": String(model.availableModels.count), "model": descriptor.model,
                      "displayName": descriptor.displayName, "effort": effort,
                      "appliesToFollowingFreshAndResumedTurns": "true"], report: &report, at: reportURL)
            }

            begin("real-pdf-text-selection", report: &report, at: reportURL)
            let passage = "Spaced review improves recall by revisiting information over time."
            let fullText = textPage.string ?? ""
            let range = (fullText as NSString).range(of: passage)
            try require(range.location != NSNotFound, "The synthetic prose is not extractable from the actual imported PDF.")
            guard let textSelection = textPage.selection(for: range) else {
                throw Failure("PDFKit could not select the actual text passage.")
            }
            let rects = textSelection.selectionsByLine().map { $0.bounds(for: textPage) }
                .filter { !$0.isEmpty && !$0.isNull }
                .map { PageRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
            try require(!rects.isEmpty, "PDFKit returned no stable page rectangles for the selected passage.")
            model.receiveSelection(ReaderSelection(pageIndex: 0, pageLabel: textPage.label ?? "1",
                text: textSelection.string ?? "", rects: rects, imageData: nil, surroundingText: fullText))
            model.startDiscussion()
            guard let textDiscussionID = model.currentDiscussion?.id else { throw Failure("Could not create a selection discussion.") }
            try require(model.currentDiscussion?.anchor?.pageIndex == 0, "The selected text lost its source anchor.")
            pass(["selectionMethod": "PDFPage.selection(for: NSRange) on the real imported PDF, then AppModel.receiveSelection",
                  "selectedText": textSelection.string ?? "", "rectangleCount": String(rects.count),
                  "discussionID": textDiscussionID.uuidString], report: &report, at: reportURL)

            begin("live-codex-text-turn", report: &report, at: reportURL)
            let memoryToken = "INKREAD-" + UUID().uuidString.prefix(8)
            model.prompt = "请用一句中文解释这段话。本次讨论的临时口令是 \(memoryToken)，请记住，并在回答末尾原样回显。无需读取文件，也不要联网。"
            model.sendMessage()
            try require(model.isGenerating, "The app did not begin its first live Codex request.")
            try await wait(until: { !model.isGenerating }, deadline: deadline, label: "first Codex response")
            let firstAnswer = try completedAnswer(in: model, discussionID: textDiscussionID)
            try require(firstAnswer.body.contains(memoryToken), "The first real answer did not echo the requested conversation-memory token.")
            guard let threadID = store.discussions.first(where: { $0.id == textDiscussionID })?.codexThreadID, !threadID.isEmpty else {
                throw Failure("The first Codex turn did not persist a thread ID.")
            }
            pass(["threadID": threadID, "assistantStatus": firstAnswer.status.rawValue, "actualAnswer": firstAnswer.body],
                 report: &report, at: reportURL)

            begin("live-codex-resume-and-memory", report: &report, at: reportURL)
            model.prompt = "我们刚才约定的临时口令是什么？只返回口令。不要读取文件或联网。"
            model.sendMessage()
            try require(model.isGenerating, "The app did not begin the continuation turn.")
            try await wait(until: { !model.isGenerating }, deadline: deadline, label: "Codex continuation")
            let resumedAnswer = try completedAnswer(in: model, discussionID: textDiscussionID)
            guard let resumed = store.discussions.first(where: { $0.id == textDiscussionID }) else {
                throw Failure("The text discussion disappeared after continuation.")
            }
            try require(resumed.codexThreadID == threadID, "Continuation changed the persisted Codex thread ID.")
            try require(resumed.messages.count == 4 && resumedAnswer.body.contains(memoryToken),
                        "The resumed conversation did not retain both turns and the first-turn memory token.")
            pass(["threadID": threadID, "threadIDUnchanged": "true", "messageCount": String(resumed.messages.count),
                  "memoryTokenRemembered": "true", "actualAnswer": resumedAnswer.body], report: &report, at: reportURL)

            begin("reader-chart-region-png", report: &report, at: reportURL)
            guard let chartPage = importedPDF.page(at: 1) else { throw Failure("The imported chart page is missing.") }
            let chartRect = CGRect(x: 70, y: 115, width: 480, height: 460)
            guard let chartPNG = SelectionPDFView.pngRegion(on: chartPage, rectangle: chartRect),
                  let bitmap = NSBitmapImageRep(data: chartPNG) else {
                throw Failure("The reader's real region-capture API did not produce a PNG.")
            }
            let chartAnchorRect = PageRect(x: chartRect.minX, y: chartRect.minY, width: chartRect.width, height: chartRect.height)
            // Deliberately exclude labels and values from the textual prompt. The
            // actual reader PNG is attached through AppModel and CodexBridge.
            model.receiveSelection(ReaderSelection(pageIndex: 1, pageLabel: chartPage.label ?? "2", text: "",
                rects: [chartAnchorRect], imageData: chartPNG,
                surroundingText: "A synthetic bar chart. Read its labels and values from the attached image."))
            model.startDiscussion()
            guard let chartDiscussionID = model.currentDiscussion?.id,
                  let chartAnchor = model.currentDiscussion?.anchor,
                  let imagePath = chartAnchor.imageRelativePath else {
                throw Failure("The app did not create an image-backed chart discussion.")
            }
            try require(try Data(contentsOf: store.assetURL(relativePath: imagePath)) == chartPNG,
                        "The persisted image attachment does not match the actual reader capture.")
            pass(["captureMethod": "SelectionPDFView.pngRegion(on:rectangle:)", "pixels": "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)",
                  "pngBytes": String(chartPNG.count), "numericTextIncludedInPrompt": "false", "imageRelativePath": imagePath,
                  "discussionID": chartDiscussionID.uuidString], report: &report, at: reportURL)

            begin("live-codex-chart-image-turn", report: &report, at: reportURL)
            model.prompt = "只根据附图读出三个柱的名称和数值，以及最高的柱。严格只输出一行，格式为 A=数值; B=数值; C=数值; MAX=最高柱名:数值。不要读取任何文件或联网；图片若无法辨认请直说。"
            model.sendMessage()
            try require(model.isGenerating, "The app did not begin its image-backed Codex request.")
            try await wait(until: { !model.isGenerating }, deadline: deadline, label: "Codex chart-image response")
            let chartAnswer = try completedAnswer(in: model, discussionID: chartDiscussionID)
            let normalized = chartAnswer.body.lowercased()
            let expectedReadings = [#"a\s*[:=：]\s*10\b"#, #"b\s*[:=：]\s*20\b"#,
                                    #"c\s*[:=：]\s*30\b"#, #"max\s*[:=：]\s*c\s*[:=：]\s*30\b"#]
            try require(expectedReadings.allSatisfy { normalized.range(of: $0, options: .regularExpression) != nil },
                        "The actual image answer did not identify C as the highest bar with value 30: \(chartAnswer.body)")
            pass(["assistantStatus": chartAnswer.status.rawValue, "actualAnswer": chartAnswer.body,
                  "expectedHighestBar": "C", "expectedHighestValue": "30"], report: &report, at: reportURL)

            begin("save-real-assistant-answer-as-note", report: &report, at: reportURL)
            model.openNoteEditor(answer: chartAnswer)
            model.noteTitle = "Live smoke test: chart conclusion"
            try require(model.noteBody == chartAnswer.body, "The note editor did not use the real assistant answer.")
            model.saveNote()
            guard let savedNote = store.notes.first(where: { $0.discussionID == chartDiscussionID }) else {
                throw Failure(model.errorMessage ?? "The app did not persist the note.")
            }
            try require(savedNote.body == chartAnswer.body && savedNote.anchors.first == chartAnchor,
                        "The saved note lost its answer or original-image anchor.")
            pass(["noteID": savedNote.id.uuidString, "discussionID": chartDiscussionID.uuidString,
                  "bodyEqualsRealAssistantAnswer": "true", "anchorRetained": "true"], report: &report, at: reportURL)

            begin("reload-library-and-anchor-jump", report: &report, at: reportURL)
            let reopened = try LibraryStore(rootURL: root)
            try require(reopened.books.count == 1 && reopened.discussions.count == 2 && reopened.notes.count == 1,
                        "Reloading the actual manifest did not recover one book, two discussions and one note.")
            try require(reopened.discussions.first(where: { $0.id == textDiscussionID })?.messages.count == 4,
                        "Reloading lost a text-discussion turn.")
            try require(reopened.discussions.first(where: { $0.id == textDiscussionID })?.codexThreadID == threadID,
                        "Reloading lost the reusable Codex thread ID.")
            try require(reopened.discussions.first(where: { $0.id == chartDiscussionID })?.anchor == chartAnchor &&
                        reopened.notes.first?.body == chartAnswer.body,
                        "Reloading lost the image anchor or real assistant note.")
            model.jumpTo(chartAnchor)
            try require(model.readerJump?.pageIndex == 1 && model.readerJump?.rects == [chartAnchorRect],
                        "AppModel.jumpTo did not restore the saved chart page and rectangle.")
            pass(["books": "1", "discussions": "2", "notes": "1", "imageAttachmentRetained": "true",
                  "jumpValidation": "AppModel.jumpTo produced the persisted pageIndex and page-coordinate rectangles; no mouse UI automation."],
                 report: &report, at: reportURL)

            begin("export-real-library-markdown", report: &report, at: reportURL)
            let markdownURL = root.appendingPathComponent("smoke-reading-notes.md")
            try reopened.exportMarkdown(for: book, to: markdownURL)
            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            try require(markdown.contains(chartAnswer.body) && markdown.contains(savedNote.title) &&
                        markdown.contains(textDiscussionID.uuidString) && markdown.contains(chartDiscussionID.uuidString) &&
                        markdown.contains("#page=2") && markdown.contains(imagePath),
                        "The actual Markdown export is missing answers, discussions or source-image links.")
            report.markdownExport = markdownURL.path
            pass(["path": markdownURL.path, "bytes": String(markdown.utf8.count),
                  "containsBothDiscussionsAndRealNote": "true", "containsPDFAndImageSourceLinks": "true"],
                 report: &report, at: reportURL)
            if environment["INKREAD_SMOKE_EXTENDED"] == "1" {
                begin("multi-material-basket-and-two-images", report: &report, at: reportURL)
                model.clearContextBasket()
                guard let textAnchor = store.discussions.first(where: { $0.id == textDiscussionID })?.anchor else { throw Failure("Missing original text anchor") }
                model.addAnchorToContext(textAnchor)
                for rectangle in [CGRect(x: 115, y: 130, width: 110, height: 230), CGRect(x: 260, y: 130, width: 110, height: 330)] {
                    guard let data = SelectionPDFView.pngRegion(on: chartPage, rectangle: rectangle) else { throw Failure("Could not capture a second chart crop") }
                    model.receiveSelection(ReaderSelection(pageIndex: 1, pageLabel: "2", text: "", rects: [PageRect(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: rectangle.height)], imageData: data, surroundingText: "A self-created chart crop. Read the image, not any file."))
                    model.addSelectionToContext()
                }
                try require(model.contextItems.count == 3, "Basket did not preserve prose plus two different chart crops")
                model.startDiscussion(useSelection: false)
                guard let combinedID = model.currentDiscussion?.id else { throw Failure("Could not create a combined discussion") }
                model.prompt = "只根据本次材料，按两张图片的顺序给出柱名和数值，格式 A=数值; B=数值。然后用一句中文概括文字材料主题。不要读取文件或联网。"
                model.sendMessage()
                try require(model.isGenerating, "Combined turn did not start")
                model.prompt = "下一问草稿：请进一步解释这个概念。"
                try await wait(until: { !model.isGenerating }, deadline: deadline, label: "combined text and two-image response")
                let combined = try completedAnswer(in: model, discussionID: combinedID)
                try require(combined.body.lowercased().range(of: #"a\s*[:=：]\s*10\b"#, options: .regularExpression) != nil && combined.body.lowercased().range(of: #"b\s*[:=：]\s*20\b"#, options: .regularExpression) != nil, "Combined images were not both read correctly: \(combined.body)")
                let snapshot = model.currentDiscussion?.messages.first?.contextItems ?? []
                try require(snapshot.count == 3 && snapshot.compactMap { $0.anchor?.imageRelativePath }.count == 2, "User turn did not retain exact three-material/two-image snapshot")
                try require(model.prompt.hasPrefix("下一问草稿"), "Completing an answer overwrote the next-question draft")
                model.clearContextBasket()
                try require(model.currentDiscussion?.messages.first?.contextItems == snapshot, "Clearing live basket changed a submitted snapshot")
                model.openNoteEditor(answer: combined)
                model.noteTitle = "Combined materials conclusion"
                model.saveNote()
                try require(store.notes.first(where: { $0.discussionID == combinedID })?.anchors.count == 3, "Combined answer note lost its three source anchors")
                let reloaded = try LibraryStore(rootURL: root)
                try require(reloaded.discussions.first(where: { $0.id == combinedID })?.messages.first?.contextItems == snapshot, "Reload lost combined context snapshot")
                pass(["actualAnswer": combined.body, "materials": "3", "images": "2", "nextDraftPreserved": "true", "noteSourceAnchors": "3", "snapshotIndependentOfBasket": "true"], report: &report, at: reportURL)

                begin("tag-suggestions-and-reviewed-save", report: &report, at: reportURL)
                model.openTagsEditor()
                let previousTags = model.selectedBook?.tags ?? []
                model.suggestTags()
                try await wait(until: { !model.isOrganizing }, deadline: deadline, label: "Codex tag suggestions")
                try require(!model.suggestedTags.isEmpty, "Tag suggestions did not parse: \(model.featureStatus)")
                try require(model.selectedBook?.tags == previousTags, "AI suggestions changed tags before user confirmation")
                let proposed = model.suggestedTags
                model.toggleSuggestedTag(proposed[0]); model.saveTags()
                try require(model.selectedBook?.tags.contains(proposed[0]) == true, "Confirmed tag was not saved")
                pass(["suggestedTags": proposed.joined(separator: ", "), "reviewRequired": "true"], report: &report, at: reportURL)

                begin("term-suggestion-and-chapter-save", report: &report, at: reportURL)
                model.receiveSelection(ReaderSelection(pageIndex: 0, pageLabel: "1", text: passage, rects: rects, imageData: nil, surroundingText: fullText))
                model.openTermEditor(); model.termName = "Spaced review"; model.termScope = "Synthetic page 1"
                model.suggestTermMeaning()
                try await wait(until: { !model.isOrganizing }, deadline: deadline, label: "Codex term definition")
                try require(!model.termMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Term suggestion returned no editable definition: \(model.featureStatus)")
                try require(store.terms.isEmpty, "Term was saved before user confirmation")
                let meaning = model.termMeaning; model.saveTerm()
                let entry = store.terms.first
                try require(entry?.term == "Spaced review" && entry?.scope == "Synthetic page 1" && entry?.anchors.first?.pageIndex == 0, "Saved term lost chapter or source")
                pass(["term": "Spaced review", "actualDefinition": meaning, "chapterAndAnchorPreserved": "true", "reviewRequired": "true"], report: &report, at: reportURL)
            }
            if languageChecks {
                begin("contextual-word-translation-and-source-snapshot", report: &report, at: reportURL)
                let word = "recall"
                let wordRange = (fullText as NSString).range(of: word)
                try require(wordRange.location != NSNotFound, "The word-translation fixture is not extractable.")
                guard let selectedWord = textPage.selection(for: wordRange) else { throw Failure("PDFKit did not select the word fixture.") }
                let wordRects = selectedWord.selectionsByLine().map { $0.bounds(for: textPage) }
                    .filter { !$0.isEmpty && !$0.isNull }
                    .map { PageRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
                try require(!wordRects.isEmpty, "The translation selection has no page coordinates.")
                let originalTerms = store.terms.count
                let originalDiscussions = store.discussions.count
                let originalMessages = store.discussions.reduce(0) { $0 + $1.messages.count }
                model.receiveSelection(ReaderSelection(pageIndex: 0, pageLabel: "1", text: selectedWord.string ?? word,
                    rects: wordRects, imageData: nil, surroundingText: fullText))
                model.translateSelection()
                try require(model.showTranslation && model.isTranslating, "The explicit translate action did not start a translation.")
                let capturedAnchor = model.translationAnchor
                // Reading and selecting a new passage must not retarget the
                // in-flight translation, its source link or its later term save.
                model.receiveSelection(ReaderSelection(pageIndex: 1, pageLabel: "2", text: "Synthetic bar chart",
                    rects: [chartAnchorRect], imageData: nil, surroundingText: "An unrelated page selected after translation started."))
                try await wait(until: { !model.isTranslating }, deadline: deadline, label: "contextual word translation")
                let translation = model.translationText
                try require(model.translationError == nil && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            model.translationError ?? "Translation returned an empty result.")
                try require(translation.range(of: #"\p{Han}"#, options: .regularExpression) != nil,
                            "The English word translation did not contain a Chinese explanation: \(translation)")
                try require(["记忆", "回忆", "回想", "记住", "记起"].contains(where: translation.contains),
                            "The translation did not explain recall in the learning context: \(translation)")
                try require(model.translationTerm == word && model.translationAnchor == capturedAnchor &&
                            capturedAnchor?.pageIndex == 0 && capturedAnchor?.rects == wordRects && capturedAnchor?.selectedText == word,
                            "Selecting another passage changed the captured translation source.")
                try require(store.terms.count == originalTerms && store.discussions.count == originalDiscussions &&
                            store.discussions.reduce(0) { $0 + $1.messages.count } == originalMessages,
                            "A word lookup changed saved terminology or the reading discussion before explicit save.")
                try require(model.canSaveTranslation, "A completed translation is not available to save.")
                pass(["word": word, "actualTranslation": translation, "sourcePage": "1", "readerMovedToPage": "2",
                      "capturedSourceUnchanged": "true", "discussionUnchanged": "true", "explicitSaveRequired": "true"],
                     report: &report, at: reportURL)

                begin("translation-glossary-save-reload-and-source-jump", report: &report, at: reportURL)
                model.saveTranslationToGlossary()
                guard let translatedTerm = store.terms.first(where: { $0.term == word && $0.meaning == translation }) else {
                    throw Failure(model.errorMessage ?? "The explicit save did not create the translated glossary entry.")
                }
                try require(store.terms.count == originalTerms + 1 && translatedTerm.documentID == book.id &&
                            translatedTerm.anchors == capturedAnchor.map { [$0] },
                            "The saved translation lost its captured book, word or original selection anchor.")
                model.saveTranslationToGlossary()
                try require(store.terms.count == originalTerms + 1, "Saving the same lookup twice created duplicate terms.")
                model.closeTranslation()
                let languageReload = try LibraryStore(rootURL: root)
                guard let reloadedTerm = languageReload.terms.first(where: { $0.id == translatedTerm.id }) else {
                    throw Failure("Reloading lost the translated glossary entry.")
                }
                try require(reloadedTerm.id == translatedTerm.id && reloadedTerm.documentID == translatedTerm.documentID &&
                            reloadedTerm.term == translatedTerm.term && reloadedTerm.meaning == translatedTerm.meaning &&
                            reloadedTerm.scope == translatedTerm.scope && reloadedTerm.anchors == translatedTerm.anchors,
                            "Reloading changed the translated glossary content or exact source anchors.")
                // The existing manifest's ISO-8601 date strategy stores whole
                // seconds. Content, IDs and page coordinates must remain exact;
                // only the documented timestamp precision may be normalized.
                try require(abs(reloadedTerm.createdAt.timeIntervalSince(translatedTerm.createdAt)) < 1 &&
                            abs(reloadedTerm.updatedAt.timeIntervalSince(translatedTerm.updatedAt)) < 1,
                            "Reloading changed the translated glossary timestamps beyond persisted precision.")
                guard let source = translatedTerm.anchors.first else { throw Failure("The translated term has no original source to jump to.") }
                model.jumpTo(source)
                try require(model.readerJump?.pageIndex == 0 && model.readerJump?.rects == wordRects,
                            "The translated term did not jump to its original word after reading moved elsewhere.")
                pass(["termID": translatedTerm.id.uuidString, "scope": translatedTerm.scope,
                      "capturedSourceRetained": "true", "repeatSaveIsIdempotent": "true", "reloadAndJumpPassed": "true"],
                     report: &report, at: reportURL)
            }
            report.status = "passed"
            model.notice = "真实 Codex 集成自测通过，报告与测试书库已保存。"
        } catch {
            model.cancelResponse()
            model.closeTranslation()
            let detail = error.localizedDescription
            report.status = "failed"
            report.error = detail
            if let index = report.steps.indices.last {
                report.steps[index].status = "failed"
                report.steps[index].durationSeconds = Date().timeIntervalSince(report.steps[index].startedAt)
                report.steps[index].details["error"] = detail
            }
            // The automated test reports errors through its durable JSON and
            // stderr. A SwiftUI alert/sheet could block normal AppKit termination.
            model.errorMessage = nil
            model.showNoteEditor = false
            FileHandle.standardError.write(Data("INKREAD_SMOKE_FAILED [\(report.currentStep)]: \(detail)\n".utf8))
        }
        if let oldLastBookID { UserDefaults.standard.set(oldLastBookID, forKey: "lastBookID") }
        else { UserDefaults.standard.removeObject(forKey: "lastBookID") }
        report.finishedAt = Date()
        write(report, to: reportURL)
        print("INKREAD_SMOKE_TEST \(report.status): \(reportURL?.path ?? "report path unavailable")")
        // Finish by following the normal AppKit termination path. Errors and all
        // intermediate steps are already durable in the JSON report for diagnosis.
        try? await Task.sleep(nanoseconds: 300_000_000)
        model.errorMessage = nil
        model.showNoteEditor = false
        NSApp.terminate(nil)
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func completedAnswer(in model: AppModel, discussionID: UUID) throws -> ChatMessage {
        guard let discussion = model.store?.discussions.first(where: { $0.id == discussionID }),
              let answer = discussion.messages.last, answer.role == .assistant,
              answer.status == .completed, !answer.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let persisted = model.store?.discussions.first(where: { $0.id == discussionID })?.messages.last?.body ?? "No assistant message was persisted."
            throw Failure(model.errorMessage ?? "Codex did not complete a nonempty answer: \(persisted)")
        }
        return answer
    }

    private static func wait(until condition: () -> Bool, deadline: Date, label: String) async throws {
        while !condition() {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure("The live smoke-test deadline expired while waiting for \(label).") }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure(detail) }
    }

    private static func begin(_ name: String, report: inout Report, at url: URL?) {
        report.currentStep = name
        report.steps.append(Step(name: name))
        write(report, to: url)
    }

    private static func pass(_ details: [String: String], report: inout Report, at url: URL?) {
        guard let index = report.steps.indices.last else { return }
        report.steps[index].status = "passed"
        report.steps[index].durationSeconds = Date().timeIntervalSince(report.steps[index].startedAt)
        report.steps[index].details = details
        write(report, to: url)
    }

    private static func write(_ report: Report, to url: URL?) {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            print("INKREAD_SMOKE_REPORT_WRITE_FAILED: \(error.localizedDescription)")
        }
    }

    private static func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                  [kCGPDFContextTitle as String: "InkRead Synthetic Reading Test",
                   kCGPDFContextCreator as String: "InkRead opt-in live smoke test"] as CFDictionary) else {
            throw Failure("Could not create the synthetic PDF graphics context.")
        }
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 16, color: CGColor = CGColor(gray: 0.08, alpha: 1)) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let string = NSAttributedString(string: value,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                             NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        func whitePage() {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
        }
        whitePage()
        text("InkRead Synthetic Reading Test", x: 50, y: 720, size: 23)
        text("Page 1: A reading passage", x: 50, y: 675, size: 19)
        text("Spaced review improves recall by revisiting information over time.", x: 50, y: 620, size: 15)
        text("Active recall asks learners to answer before reading an explanation.", x: 50, y: 586, size: 15)
        text("Both methods support deliberate learning and thoughtful review.", x: 50, y: 552, size: 15)
        text("This document contains only fictional, self-created test material.", x: 50, y: 470, size: 13)
        context.endPDFPage()

        whitePage()
        text("Page 2: Interpret the attached figure", x: 50, y: 720, size: 23)
        text("Synthetic bar chart", x: 120, y: 540, size: 22)
        context.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 110, y: 180))
        context.addLine(to: CGPoint(x: 530, y: 180))
        context.strokePath()
        let entries: [(String, Int, CGFloat, CGColor)] = [
            ("A", 10, 135, CGColor(red: 0.15, green: 0.40, blue: 0.75, alpha: 1)),
            ("B", 20, 280, CGColor(red: 0.12, green: 0.58, blue: 0.42, alpha: 1)),
            ("C", 30, 425, CGColor(red: 0.78, green: 0.30, blue: 0.18, alpha: 1))
        ]
        for (label, value, x, color) in entries {
            let height = CGFloat(value) * 10
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: 180, width: 65, height: height))
            text(label, x: x + 24, y: 150, size: 22)
            text(String(value), x: x + 18, y: 190 + height, size: 22)
        }
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
}
