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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectionPDFView {
        let view = SelectionPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
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
            view.removeManagedHighlights()
            view.document = PDFDocument(url: identity)
            coordinator.loadedURL = identity
            coordinator.suppressesSelection = false
        }
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
    }

    static func dismantleNSView(_ nsView: SelectionPDFView, coordinator: Coordinator) {
        coordinator.disconnect()
        nsView.onRegionCaptured = nil
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

        init(_ parent: PDFReaderView) { self.parent = parent }

        func connect(_ view: SelectionPDFView) {
            reader = view
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(selectionChanged(_:)),
                               name: .PDFViewSelectionChanged, object: view)
            center.addObserver(self, selector: #selector(pageChanged(_:)),
                               name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: .PDFViewScaleChanged, object: view)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: NSView.boundsDidChangeNotification, object: nil)
        }

        func disconnect() {
            selectionTask?.cancel()
            NotificationCenter.default.removeObserver(self)
            reader = nil
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard !suppressesSelection, let reader, !reader.capturesRegion else { return }
            selectionTask?.cancel()
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
            guard let reader, let document = reader.document, let page = reader.currentPage else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            // The first notification can occur inside updateNSView. Deliver outside
            // that update before mutating the app's observable reading position.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.reader?.document === document else { return }
                self.parent.onPageChanged(index)
            }
        }

        @objc private func displayChanged(_ notification: Notification) {
            guard let reader else { return }
            if let changed = notification.object as? NSView,
               changed !== reader, !changed.isDescendant(of: reader) { return }
            reader.refreshOverlay()
        }

        func performJump(_ jump: ReaderJump) {
            guard let reader, let page = reader.document?.page(at: jump.pageIndex) else { return }
            suppressesSelection = true
            selectionTask?.cancel()
            reader.clearSelection()
            if let first = jump.rects.first {
                let region = jump.rects.dropFirst().reduce(first.cgRect) { $0.union($1.cgRect) }
                reader.go(to: region.insetBy(dx: -16, dy: -24), on: page)
            } else {
                reader.go(to: page)
            }
            reader.flash(page: page, rectangles: jump.rects.map(\.cgRect))
            lastSelectionSignature = nil
            suppressesSelection = false
        }
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
    private var startPoint: NSPoint?
    private var dragPage: PDFPage?
    fileprivate var dragRect: NSRect?
    fileprivate var flashedPage: PDFPage?
    fileprivate var flashedRects: [NSRect] = []
    private var flashTask: Task<Void, Never>?
    private var managedHighlights: [(PDFPage, PDFAnnotation)] = []
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
