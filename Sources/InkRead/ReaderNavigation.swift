import Foundation
import PDFKit
import InkReadCore

struct ReaderCommand: Equatable {
    enum Action: Equatable {
        case zoomIn, zoomOut, actualSize, fitWidth, fitPage
        case search(query: String)
        case nextMatch, previousMatch, clearSearch, clearSelection, back, forward
    }

    var token: UUID = UUID()
    var action: Action
}

struct ReaderMetrics: Equatable {
    var scaleFactor: Double
    var currentPageIndex: Int
    var pageLabel: String
    var canGoBack: Bool = false
    var canGoForward: Bool = false
}

struct ReaderSearchHit: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var pageIndex: Int
    var pageLabel: String
    var text: String
    /// Exact page-space rectangles allow a results row to use ReaderJump.
    var rects: [PageRect] = []
}

struct ReaderOutlineItem: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var pageIndex: Int
    var depth: Int
}

enum ReaderDocumentIndex {
    /// A fresh document belongs entirely to the caller's thread. Call this from
    /// Task.detached for large books; no UI PDFDocument is accessed here.
    nonisolated static func load(url: URL) -> [ReaderOutlineItem] {
        guard let document = PDFDocument(url: url), !document.isLocked,
              let root = document.outlineRoot else { return [] }
        func destinationIndex(_ node: PDFOutline) -> Int? {
            let destination = node.destination ?? (node.action as? PDFActionGoTo)?.destination
            guard let page = destination?.page else { return nil }
            let index = document.index(for: page)
            return index == NSNotFound ? nil : index
        }
        func firstPage(in node: PDFOutline) -> Int? {
            if let index = destinationIndex(node) { return index }
            for index in 0..<node.numberOfChildren {
                if let child = node.child(at: index), let page = firstPage(in: child) { return page }
            }
            return nil
        }
        var items: [ReaderOutlineItem] = []
        func flatten(_ parent: PDFOutline, path: String, depth: Int) {
            guard depth < 64 else { return }
            for index in 0..<parent.numberOfChildren {
                guard let node = parent.child(at: index) else { continue }
                let id = path.isEmpty ? String(index) : path + "." + String(index)
                let title = (node.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let page = firstPage(in: node), !title.isEmpty {
                    items.append(ReaderOutlineItem(id: id, title: title, pageIndex: page, depth: depth))
                }
                flatten(node, path: id, depth: depth + 1)
            }
        }
        flatten(root, path: "", depth: 0)
        return items
    }
}

struct ReaderSearchMatch: Sendable {
    var hit: ReaderSearchHit
    /// UTF-16 range belongs to the text of this hit's page, never a UI PDF object.
    var range: NSRange
}

enum ReaderDocumentSearch {
    /// Run on a detached task. Each search owns its own PDFDocument, and only
    /// value types cross back to the main actor. Results are capped at 200;
    /// reaching that limit does not claim an exact total for the whole book.
    nonisolated static func search(
        url: URL, query: String, limit: Int = 200,
        onBatch: @escaping @Sendable ([ReaderSearchMatch]) async -> Void
    ) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !Task.isCancelled,
              let document = PDFDocument(url: url), !document.isLocked else {
            if !Task.isCancelled { await onBatch([]) }
            return
        }
        var matches: [ReaderSearchMatch] = []
        var lastReportedCount = 0
        for pageIndex in 0..<document.pageCount {
            guard !Task.isCancelled else { return }
            guard let page = document.page(at: pageIndex), let pageString = page.string else { continue }
            let text = pageString as NSString
            var start = 0
            while start < text.length {
                guard !Task.isCancelled else { return }
                let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                let lower = max(0, range.location - 55)
                let upper = min(text.length, NSMaxRange(range) + 95)
                let snippet = text.substring(with: NSRange(location: lower, length: upper - lower))
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)).filter { !$0.isEmpty }.joined(separator: " ")
                let rects = page.selection(for: range)?.selectionsByLine()
                    .map { $0.bounds(for: page) }.filter { !$0.isNull && !$0.isEmpty }
                    .map { PageRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) } ?? []
                let hit = ReaderSearchHit(pageIndex: pageIndex, pageLabel: page.label ?? String(pageIndex + 1),
                                          text: snippet, rects: rects)
                matches.append(ReaderSearchMatch(hit: hit, range: range))
                if matches.count == 1 || matches.count - lastReportedCount >= 16 || matches.count >= limit {
                    await onBatch(matches)
                    lastReportedCount = matches.count
                }
                if matches.count >= limit { return }
                start = NSMaxRange(range)
            }
            if matches.count != lastReportedCount {
                await onBatch(matches)
                lastReportedCount = matches.count
            }
        }
        if matches.isEmpty || matches.count != lastReportedCount { await onBatch(matches) }
    }
}
