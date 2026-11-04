import AppKit
import PDFKit
import SwiftUI
import InkReadCore

struct ReaderSelection {
    var pageIndex: Int
    var pageLabel: String
    var text: String
    var rects: [PageRect]
    var imageData: Data?
    var surroundingText: String
}

struct ReaderJump: Equatable {
    var token: UUID = UUID()
    var pageIndex: Int
    var rects: [PageRect] = []
}

/// A model-driven marker. The app saves this model; the reader never rewrites its PDF.
struct ReaderHighlight: Equatable, Identifiable {
    var id: UUID = UUID()
    var pageIndex: Int
    var rects: [PageRect]
    var colorHex: String = "F8CE46"
    var isRegion: Bool = false
}

struct PDFReaderView: NSViewRepresentable {
    var url: URL
    var captureRegion: Bool
    var jump: ReaderJump?
    var onSelection: (ReaderSelection) -> Void
    var onPageChanged: (Int) -> Void
    var highlights: [ReaderHighlight] = []
    var nightReading: Bool = false
    var command: ReaderCommand? = nil
    var onMetrics: (ReaderMetrics) -> Void = { _ in }
    var onSearchResults: ([ReaderSearchHit]) -> Void = { _ in }
    var onSearchStatus: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectionPDFView {
        let view = SelectionPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        context.coordinator.connect(view)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SelectionPDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let identity = url.standardizedFileURL
        if coordinator.loadedURL != identity {
            coordinator.selectionTask?.cancel()
            coordinator.suppressesSelection = true
            coordinator.lastSelectionSignature = nil
            coordinator.lastJump = nil
            coordinator.lastHighlights = []
            coordinator.resetNavigationForDocument()
            view.removeManagedHighlights()
            let document = PDFDocument(url: identity)
            coordinator.documentDelegate.nightState.isEnabled = nightReading
            // Set the public page factory before PDFView requests its first page.
            document?.delegate = coordinator.documentDelegate
            view.document = document
            coordinator.loadedURL = identity
            coordinator.suppressesSelection = false
        }
        view.setNightReading(nightReading)
        view.capturesRegion = captureRegion
        view.onRegionCaptured = { [weak coordinator] selection in
            coordinator?.parent.onSelection(selection)
        }
        if coordinator.lastHighlights != highlights {
            view.setManagedHighlights(highlights)
            coordinator.lastHighlights = highlights
        }
        if let jump, jump != coordinator.lastJump {
            coordinator.lastJump = jump
            coordinator.performJump(jump)
        }
        if let command, command.token != coordinator.lastCommandToken {
            coordinator.lastCommandToken = command.token
            coordinator.perform(command)
        }
        coordinator.scheduleMetrics()
    }

    static func dismantleNSView(_ nsView: SelectionPDFView, coordinator: Coordinator) {
        coordinator.disconnect()
        nsView.onRegionCaptured = nil
        nsView.onViewportChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFReaderView
        weak var reader: SelectionPDFView?
        var loadedURL: URL?
        var lastJump: ReaderJump?
        var lastHighlights: [ReaderHighlight] = []
        var lastSelectionSignature: String?
        var selectionTask: Task<Void, Never>?
        var suppressesSelection = false
        let documentDelegate = ReaderPDFDocumentDelegate()
        var lastCommandToken: UUID?
        private var programmaticSelection: PDFSelection?
        private var metricsTask: Task<Void, Never>?
        private var lastMetrics: ReaderMetrics?
        private var searchTask: Task<Void, Never>?
        private var searchGeneration = UUID()
        private var searchMatches: [ReaderSearchMatch] = []
        private var activeMatchIndex = -1
        private var searchHighlightTask: Task<Void, Never>?
        private var visibleHighlightSignature = ""
        private enum ZoomMode { case manual, width, page }
        private var zoomMode = ZoomMode.manual
        private var lastViewportSize = NSSize.zero
        private var refitTask: Task<Void, Never>?

        init(_ parent: PDFReaderView) { self.parent = parent }

        func connect(_ view: SelectionPDFView) {
            reader = view
            view.onViewportChanged = { [weak self] in self?.viewportChanged() }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(selectionChanged(_:)),
                               name: .PDFViewSelectionChanged, object: view)
            center.addObserver(self, selector: #selector(pageChanged(_:)),
                               name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: .PDFViewScaleChanged, object: view)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: .PDFViewChangedHistory, object: view)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: NSView.boundsDidChangeNotification, object: nil)
        }

        func disconnect() {
            selectionTask?.cancel()
            searchTask?.cancel()
            metricsTask?.cancel()
            searchHighlightTask?.cancel()
            refitTask?.cancel()
            reader?.onViewportChanged = nil
            NotificationCenter.default.removeObserver(self)
            reader = nil
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard !suppressesSelection, let reader, !reader.capturesRegion else { return }
            selectionTask?.cancel()
            if let programmaticSelection, reader.currentSelection === programmaticSelection { return }
            if reader.currentSelection?.string?.isEmpty != false {
                lastSelectionSignature = nil
                return
            }
            // PDFKit posts while the mouse drags. Debounce so the surrounding SwiftUI
            // view does not continually rebuild and interrupt the actual selection.
            selectionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return }
                guard let self, !self.suppressesSelection,
                      let reader = self.reader, !reader.capturesRegion,
                      let selected = reader.currentSelection,
                      selected !== self.programmaticSelection,
                      let page = selected.pages.first,
                      let document = reader.document else { return }

                let index = document.index(for: page)
                guard index != NSNotFound else { return }
                // One source anchor belongs to one page. For a selection crossing a
                // page break, keep only the first page instead of misattributing text.
                let local = PDFSelection(document: document)
                for i in 0..<selected.numberOfTextRanges(on: page) {
                    if let part = page.selection(for: selected.range(at: i, on: page)) {
                        local.add(part)
                    }
                }
                let text = (local.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let rectangles = local.selectionsByLine().map { $0.bounds(for: page) }
                    .filter { !$0.isEmpty && !$0.isNull }
                let rects = (rectangles.isEmpty ? [local.bounds(for: page)] : rectangles)
                    .filter { !$0.isEmpty && !$0.isNull }.map(PageRect.init)
                guard !rects.isEmpty else { return }
                let signature = "\(index)|\(text)|\(rects)"
                guard signature != self.lastSelectionSignature else { return }
                self.lastSelectionSignature = signature
                self.parent.onSelection(ReaderSelection(
                    pageIndex: index, pageLabel: page.label ?? String(index + 1),
                    text: text, rects: rects, imageData: nil,
                    surroundingText: SelectionPDFView.contextText(on: page, selection: local)))
            }
        }

        @objc private func pageChanged(_ notification: Notification) {
            reader?.refreshOverlay()
            scheduleMetrics()
            scheduleSearchHighlights()
            guard let reader, let document = reader.document, let page = reader.currentPage else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            // The first notification can occur inside updateNSView. Deliver outside
            // that update before mutating the app's observable reading position.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let reader = self.reader, reader.document === document,
                      let currentPage = reader.currentPage, document.index(for: currentPage) == index else { return }
                self.parent.onPageChanged(index)
            }
        }

        @objc private func displayChanged(_ notification: Notification) {
            guard let reader else { return }
            if let changed = notification.object as? NSView,
               changed !== reader, !changed.isDescendant(of: reader) { return }
            reader.refreshOverlay()
            scheduleMetrics()
            scheduleSearchHighlights()
            viewportChanged()
        }

        func resetNavigationForDocument() {
            searchTask?.cancel()
            searchTask = nil
            searchGeneration = UUID()
            searchMatches = []
            activeMatchIndex = -1
            visibleHighlightSignature = ""
            programmaticSelection = nil
            lastCommandToken = nil
            lastMetrics = nil
            zoomMode = .manual
            lastViewportSize = .zero
            refitTask?.cancel()
            publishSearchResults([])
        }

        func scheduleMetrics() {
            metricsTask?.cancel()
            metricsTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let reader = self.reader,
                      let document = reader.document, let page = reader.currentPage else { return }
                let index = document.index(for: page)
                guard index != NSNotFound else { return }
                let metrics = ReaderMetrics(scaleFactor: Double(reader.scaleFactor), currentPageIndex: index,
                    pageLabel: page.label ?? String(index + 1), canGoBack: reader.canGoBack, canGoForward: reader.canGoForward)
                guard metrics != self.lastMetrics else { return }
                self.lastMetrics = metrics
                self.parent.onMetrics(metrics)
            }
        }

        func perform(_ command: ReaderCommand) {
            guard let reader else { return }
            switch command.action {
            case .zoomIn:
                zoomMode = .manual
                applyScale(reader.scaleFactor * 1.2)
            case .zoomOut:
                zoomMode = .manual
                applyScale(reader.scaleFactor / 1.2)
            case .actualSize:
                zoomMode = .manual
                applyScale(1)
            case .fitWidth:
                zoomMode = .width
                fitViewport()
            case .fitPage:
                zoomMode = .page
                fitViewport()
            case .search(let query): startSearch(query)
            case .nextMatch: moveMatch(by: 1)
            case .previousMatch: moveMatch(by: -1)
            case .clearSearch: clearSearch()
            case .clearSelection:
                internally { reader.clearSelection() }
                lastSelectionSignature = nil
            case .back:
                if reader.canGoBack { internally { reader.goBack(nil) } }
            case .forward:
                if reader.canGoForward { internally { reader.goForward(nil) } }
            }
            scheduleMetrics()
        }

        private func internally(_ action: () -> Void) {
            let previous = suppressesSelection
            suppressesSelection = true
            selectionTask?.cancel()
            action()
            // PDFKit retains this actual selection instance. Late notifications
            // for a search/jump/zoom remain suppressed after this call returns.
            programmaticSelection = reader?.currentSelection
            suppressesSelection = previous
        }

        private func viewportSize() -> NSSize {
            guard let reader else { return .zero }
            // PDFKit scales the clip view's bounds into document coordinates.
            // Its frame stays in viewport points; using bounds creates a zoom
            // feedback loop when a fit command responds to a layout change.
            return reader.documentView?.enclosingScrollView?.contentView.frame.size ?? reader.bounds.size
        }

        func viewportChanged() {
            scheduleMetrics()
            scheduleSearchHighlights()
            guard zoomMode != .manual, viewportSize() != lastViewportSize else { return }
            refitTask?.cancel()
            refitTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.fitViewport()
            }
        }

        private func applyScale(_ value: CGFloat) {
            guard let reader, value.isFinite, value > 0 else { return }
            let scale = min(max(value, reader.minScaleFactor), reader.maxScaleFactor)
            let destination = reader.currentDestination
            let selection = reader.currentSelection
            internally {
                reader.autoScales = false
                if abs(reader.scaleFactor - scale) > 0.0001 { reader.scaleFactor = scale }
                if let destination { reader.go(to: destination) }
                if let selection, reader.currentSelection !== selection {
                    reader.setCurrentSelection(selection, animate: false)
                }
            }
            scheduleMetrics()
            scheduleSearchHighlights()
        }

        private func fitViewport() {
            guard zoomMode != .manual, let reader, let page = reader.currentPage else { return }
            let viewport = viewportSize()
            guard viewport.width > 40, viewport.height > 40 else { return }
            lastViewportSize = viewport
            let pageSize = page.bounds(for: reader.displayBox).applying(page.transform(for: reader.displayBox)).size
            guard pageSize.width > 0, pageSize.height > 0 else { return }
            let margins = reader.pageBreakMargins
            let widthScale = max(1, viewport.width - margins.left - margins.right - 8) / pageSize.width
            let heightScale = max(1, viewport.height - margins.top - margins.bottom - 8) / pageSize.height
            applyScale(zoomMode == .width ? widthScale : min(widthScale, heightScale))
        }

        private func publishSearchResults(_ hits: [ReaderSearchHit]) {
            let generation = searchGeneration
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.reader != nil, self.searchGeneration == generation else { return }
                guard self.searchMatches.map(\.hit.id) == hits.map(\.id) else { return }
                self.parent.onSearchResults(hits)
            }
        }

        private func publishSearchStatus(_ searching: Bool) {
            let generation = searchGeneration
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.reader != nil, self.searchGeneration == generation else { return }
                self.parent.onSearchStatus(searching)
            }
        }

        private func clearSearch() {
            searchTask?.cancel()
            searchTask = nil
            searchGeneration = UUID()
            searchMatches = []
            activeMatchIndex = -1
            visibleHighlightSignature = ""
            if let reader {
                internally {
                    reader.highlightedSelections = nil
                    if reader.currentSelection === programmaticSelection { reader.clearSelection() }
                }
            }
            programmaticSelection = nil
            publishSearchResults([])
            publishSearchStatus(false)
        }

        private func startSearch(_ value: String) {
            clearSearch()
            let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let url = loadedURL else { return }
            let generation = searchGeneration
            publishSearchStatus(true)
            searchTask = Task.detached(priority: .userInitiated) { [weak self] in
                await ReaderDocumentSearch.search(url: url, query: query) { [weak self] matches in
                    await self?.receiveSearch(matches, generation: generation)
                }
                await self?.finishSearch(generation: generation)
            }
        }

        private func finishSearch(generation: UUID) {
            guard searchGeneration == generation else { return }
            publishSearchStatus(false)
        }

        private func receiveSearch(_ matches: [ReaderSearchMatch], generation: UUID) {
            guard searchGeneration == generation, reader != nil else { return }
            searchMatches = matches
            publishSearchResults(matches.map(\.hit))
            if activeMatchIndex < 0, !matches.isEmpty { selectMatch(at: 0) }
            scheduleSearchHighlights()
        }

        private func moveMatch(by offset: Int) {
            guard !searchMatches.isEmpty else { return }
            let count = searchMatches.count
            let next = activeMatchIndex < 0 ? (offset < 0 ? count - 1 : 0) : (activeMatchIndex + offset + count) % count
            selectMatch(at: next)
        }

        private func selectMatch(at index: Int) {
            guard searchMatches.indices.contains(index), let reader,
                  let page = reader.document?.page(at: searchMatches[index].hit.pageIndex),
                  let selection = page.selection(for: searchMatches[index].range) else { return }
            activeMatchIndex = index
            selection.color = NSColor.systemOrange.withAlphaComponent(0.65)
            internally {
                reader.setCurrentSelection(selection, animate: true)
                reader.go(to: selection)
            }
            visibleHighlightSignature = ""
            scheduleSearchHighlights()
            scheduleMetrics()
        }

        private func scheduleSearchHighlights() {
            guard !searchMatches.isEmpty else { return }
            searchHighlightTask?.cancel()
            searchHighlightTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.updateSearchHighlights()
            }
        }

        private func updateSearchHighlights() {
            guard let reader, let document = reader.document else { return }
            let visibleIndices = Set(reader.visiblePages.map { document.index(for: $0) })
            let signature = "\(searchGeneration)|\(searchMatches.count)|\(activeMatchIndex)|\(visibleIndices.sorted())"
            guard signature != visibleHighlightSignature else { return }
            visibleHighlightSignature = signature
            // Reconstitute PDFSelections only for visible pages. A large book's
            // other page text never needs decoding on the UI thread for search.
            reader.highlightedSelections = searchMatches.compactMap { match in
                guard visibleIndices.contains(match.hit.pageIndex),
                      let page = document.page(at: match.hit.pageIndex),
                      let selection = page.selection(for: match.range) else { return nil }
                selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
                return selection
            }
        }

        func performJump(_ jump: ReaderJump) {
            guard let reader, let page = reader.document?.page(at: jump.pageIndex) else { return }
            suppressesSelection = true
            selectionTask?.cancel()
            reader.clearSelection()
            programmaticSelection = nil
            if let first = jump.rects.first {
                let region = jump.rects.dropFirst().reduce(first.cgRect) { $0.union($1.cgRect) }
                reader.go(to: region.insetBy(dx: -16, dy: -24), on: page)
            } else {
                reader.go(to: page)
            }
            reader.flash(page: page, rectangles: jump.rects.map(\.cgRect))
            lastSelectionSignature = nil
            suppressesSelection = false
            scheduleMetrics()
            scheduleSearchHighlights()
        }
    }
}

/// PDFKit may draw page tiles away from the main thread. The drawing path only
/// reads this small locked state and never reaches SwiftUI or AppKit appearance.
final class ReaderNightState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }
}

final class ReaderPDFDocumentDelegate: NSObject, PDFDocumentDelegate {
    let nightState = ReaderNightState()
    func classForPage() -> AnyClass { ReaderPDFPage.self }
}

/// Transform colors inside PDFKit's original drawing context, after the native
/// PDF vectors/text have been rendered at that tile's actual resolution.
/// There is no intermediate whole-document bitmap or Core Animation filter.
final class ReaderPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard (document?.delegate as? ReaderPDFDocumentDelegate)?.nightState.isEnabled == true else {
            super.draw(with: box, to: context)
            return
        }
        let paper = bounds(for: box).applying(transform(for: box)).standardized
        context.saveGState()
        // A PDF can leave its paper transparent. Establish opaque white in the
        // same rotated/cropped display space before drawing and inverting it.
        context.setBlendMode(.normal)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(paper)
        super.draw(with: box, to: context)
        context.setBlendMode(.difference)
        context.setAlpha(0.93)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(paper)
        context.restoreGState()
    }
}

@MainActor
final class SelectionPDFView: PDFView {
    var capturesRegion = false {
        didSet {
            if capturesRegion != oldValue {
                cancelRegion()
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var onRegionCaptured: ((ReaderSelection) -> Void)?
    var onViewportChanged: (() -> Void)?
    private var startPoint: NSPoint?
    private var dragPage: PDFPage?
    fileprivate var dragRect: NSRect?
    fileprivate var flashedPage: PDFPage?
    fileprivate var flashedRects: [NSRect] = []
    private var flashTask: Task<Void, Never>?
    private var managedHighlights: [(PDFPage, PDFAnnotation)] = []
    private var nightReadingEnabled = false
    private lazy var overlay: ReaderOverlayView = {
        let view = ReaderOverlayView()
        view.reader = self
        view.autoresizingMask = [.width, .height]
        return view
    }()

    override func layout() {
        super.layout()
        if subviews.last !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.frame = bounds
        overlay.needsDisplay = true
        onViewportChanged?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = .windowBackgroundColor
        refreshOverlay()
        needsDisplay = true
    }

    /// Toggle the original PDFPage renderer's color transform and invalidate its
    /// native page tiles. Document identity, scale, scroll and selection survive.
    func setNightReading(_ enabled: Bool) {
        let state = (document?.delegate as? ReaderPDFDocumentDelegate)?.nightState
        let stateChanged = state?.isEnabled != enabled
        state?.isEnabled = enabled
        guard nightReadingEnabled != enabled || stateChanged else { return }
        nightReadingEnabled = enabled
        func invalidate(_ layer: CALayer) {
            layer.setNeedsDisplay()
            for child in layer.sublayers ?? [] { invalidate(child) }
        }
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            if let layer = view.layer { invalidate(layer) }
            for child in view.subviews { invalidate(child) }
        }
        if let documentView { invalidate(documentView) }
        needsDisplay = true
        refreshOverlay()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        // PDFView hosts its document in internal subviews. Claim region-capture
        // mouse events here; otherwise PDFKit would begin a text selection instead.
        return capturesRegion && target != nil ? self : target
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if capturesRegion { addCursorRect(visibleRect, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard capturesRegion else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return }
        window?.makeFirstResponder(self)
        startPoint = point
        dragPage = page
        dragRect = NSRect(origin: point, size: .zero)
        refreshOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        guard capturesRegion else { super.mouseDragged(with: event); return }
        guard let startPoint, let dragPage else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pageBounds = convert(dragPage.bounds(for: .cropBox), from: dragPage)
        let clamped = NSPoint(x: min(max(point.x, pageBounds.minX), pageBounds.maxX),
                              y: min(max(point.y, pageBounds.minY), pageBounds.maxY))
        dragRect = NSRect(x: min(startPoint.x, clamped.x), y: min(startPoint.y, clamped.y),
                          width: abs(startPoint.x - clamped.x), height: abs(startPoint.y - clamped.y))
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        guard capturesRegion else { super.mouseUp(with: event); return }
        defer { cancelRegion() }
        guard let dragPage, let dragRect, dragRect.width >= 6, dragRect.height >= 6,
              let document else { return }
        let region = convert(dragRect, to: dragPage).standardized
            .intersection(dragPage.bounds(for: .cropBox))
        let index = document.index(for: dragPage)
        guard !region.isNull, !region.isEmpty, index != NSNotFound,
              let data = Self.pngRegion(on: dragPage, rectangle: region) else { return }
        let selection = dragPage.selection(for: region)
        onRegionCaptured?(ReaderSelection(
            pageIndex: index, pageLabel: dragPage.label ?? String(index + 1),
            text: (selection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            rects: [PageRect(region)], imageData: data,
            surroundingText: Self.contextText(on: dragPage, selection: selection)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, startPoint != nil { cancelRegion(); return }
        super.keyDown(with: event)
    }

    private func cancelRegion() {
        startPoint = nil
        dragPage = nil
        dragRect = nil
        refreshOverlay()
    }

    func refreshOverlay() { overlay.needsDisplay = true }

    func flash(page: PDFPage, rectangles: [NSRect]) {
        flashTask?.cancel()
        flashedPage = page
        flashedRects = rectangles
        refreshOverlay()
        flashTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_400_000_000) }
            catch { return }
            self?.flashedPage = nil
            self?.flashedRects = []
            self?.refreshOverlay()
        }
    }

    func removeManagedHighlights() {
        for (page, annotation) in managedHighlights { page.removeAnnotation(annotation) }
        managedHighlights = []
    }

    func setManagedHighlights(_ highlights: [ReaderHighlight]) {
        removeManagedHighlights()
        for highlight in highlights {
            guard let page = document?.page(at: highlight.pageIndex) else { continue }
            let color = NSColor.readerHex(highlight.colorHex)
                .withAlphaComponent(highlight.isRegion ? 1 : 0.35)
            for rect in highlight.rects where rect.width > 0 && rect.height > 0 {
                let annotation = PDFAnnotation(bounds: rect.cgRect,
                    forType: highlight.isRegion ? .square : .highlight, withProperties: nil)
                annotation.color = color
                if highlight.isRegion {
                    annotation.interiorColor = nil
                    let border = PDFBorder()
                    border.lineWidth = 1.5
                    annotation.border = border
                }
                annotation.userName = "InkRead"
                page.addAnnotation(annotation)
                managedHighlights.append((page, annotation))
            }
        }
        needsDisplay = true
    }

    /// Render original PDF content, independently of zoom and the capture overlay.
    /// The transform handles inherited page rotation and nonzero crop-box origins.
    static func pngRegion(on page: PDFPage, rectangle: CGRect) -> Data? {
        guard let source = page.pageRef else { return nil }
        let box = source.getBoxRect(.cropBox)
        let rotated = (source.rotationAngle % 180) != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let transform = source.getDrawingTransform(.cropBox,
            rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: false)
        let renderedRect = rectangle.applying(transform).standardized
        guard renderedRect.width > 0, renderedRect.height > 0 else { return nil }
        // About 144 dpi, with a cap for unusually large engineering pages.
        let scale = min(2.0, sqrt(20_000_000 / (renderedRect.width * renderedRect.height)),
                        8000 / max(renderedRect.width, renderedRect.height))
        let width = max(1, Int(ceil(renderedRect.width * scale)))
        let height = max(1, Int(ceil(renderedRect.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -renderedRect.minX, y: -renderedRect.minY)
        context.concatenate(transform)
        context.drawPDFPage(source)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func contextText(on page: PDFPage, selection: PDFSelection?) -> String {
        let fullText = (page.string ?? "") as NSString
        guard fullText.length > 0 else { return "" }
        guard let selection, selection.numberOfTextRanges(on: page) > 0 else {
            return fullText.substring(to: min(fullText.length, 6000))
        }
        let selected = selection.range(at: 0, on: page)
        guard selected.location != NSNotFound, selected.location <= fullText.length else {
            return fullText.substring(to: min(fullText.length, 6000))
        }
        let lower = max(0, selected.location - 1600)
        let upper = min(fullText.length, selected.location + min(selected.length, fullText.length - selected.location) + 1600)
        return fullText.substring(with: NSRange(location: lower, length: min(upper - lower, 8000)))
    }
}

@MainActor
private final class ReaderOverlayView: NSView {
    weak var reader: SelectionPDFView?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let reader else { return }
        if let page = reader.flashedPage {
            for rectangle in reader.flashedRects {
                let rect = reader.convert(rectangle, from: page)
                NSColor.systemYellow.withAlphaComponent(0.28).setFill()
                NSBezierPath(rect: rect).fill()
                NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 1.5
                border.stroke()
            }
        }
        if let rect = reader.dragRect {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
        }
    }
}

private extension PageRect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private extension NSColor {
    static func readerHex(_ string: String) -> NSColor {
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return .systemYellow }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
