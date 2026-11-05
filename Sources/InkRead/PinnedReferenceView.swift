import AppKit
import PDFKit
import SwiftUI
import InkReadCore

/// An independent, vector PDF reference pane. Its single-page document prevents
/// navigation away from the pinned page without changing the main reader.
@MainActor
struct PinnedReferenceView: View {
    var url: URL
    var anchor: SourceAnchor
    var nightReading: Bool
    var onJump: () -> Void
    var onClose: () -> Void

    @State private var pageDocument: PinnedPageDocument?
    @State private var loadFailed = false
    @State private var command: ReaderCommand?

    private var pageIdentity: String { url.standardizedFileURL.path + "#" + String(anchor.pageIndex) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
                Text("固定参考 · PDF 第 \(anchor.pageIndex + 1) 页")
                    .font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Button("放大参考页") { command = ReaderCommand(action: .zoomIn) }
                    Button("缩小参考页") { command = ReaderCommand(action: .zoomOut) }
                    Divider()
                    Button("适合宽度") { command = ReaderCommand(action: .fitWidth) }
                    Button("查看整页") { command = ReaderCommand(action: .fitPage) }
                } label: { Image(systemName: "plus.magnifyingglass") }
                    .menuStyle(.borderlessButton).fixedSize().help("参考页缩放")
                Button(action: onJump) { Image(systemName: "arrow.up.forward") }
                    .font(.caption).help("在主阅读区打开这处原文").accessibilityLabel("固定参考跳原文")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("关闭固定参考").accessibilityLabel("关闭固定参考")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()
            Group {
                if let pageDocument {
                    PinnedNativePDFView(pageDocument: pageDocument, identity: pageIdentity, anchor: anchor,
                                        nightReading: nightReading, command: command)
                } else if loadFailed {
                    Text("无法打开固定页，请重新选择原文。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: pageIdentity) {
            pageDocument = nil
            loadFailed = false
            command = nil
            let sourceURL = url
            let pageIndex = anchor.pageIndex
            let worker = Task.detached(priority: .userInitiated) { () -> Data? in
                guard !Task.isCancelled else { return nil }
                return try? Data(contentsOf: sourceURL, options: .mappedIfSafe)
            }
            let data = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            // Keep all PDFKit objects on the main actor. In-memory page copying
            // preserves complex-font ToUnicode maps that PDFKit's one-page
            // dataRepresentation serialization can change despite equal glyphs.
            pageDocument = data.flatMap { PinnedPageDocument(sourceData: $0, pageIndex: pageIndex) }
            loadFailed = pageDocument == nil
        }
    }
}

@MainActor
final class PinnedPageDocument {
    let sourceDocument: PDFDocument
    let document: PDFDocument
    let documentDelegate = ReaderPDFDocumentDelegate()

    init?(sourceData: Data, pageIndex: Int) {
        guard let source = PDFDocument(data: sourceData), !source.isLocked,
              pageIndex >= 0, pageIndex < source.pageCount else { return nil }
        source.delegate = documentDelegate
        guard let original = source.page(at: pageIndex),
              let copy = original.copy() as? ReaderPDFPage else { return nil }
        let singlePage = PDFDocument()
        singlePage.delegate = documentDelegate
        singlePage.insert(copy, at: 0)
        // Retain the original document and weak delegate's owner for every font
        // resource used by the native copied page. No PDF serialization occurs.
        sourceDocument = source
        document = singlePage
    }
}

struct PinnedNativePDFView: NSViewRepresentable {
    var pageDocument: PinnedPageDocument
    var identity: String
    var anchor: SourceAnchor
    var nightReading: Bool
    var command: ReaderCommand?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectionPDFView {
        let view = SelectionPDFView()
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = false
        view.backgroundColor = .windowBackgroundColor
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        context.coordinator.reader = view
        view.onViewportChanged = { [weak coordinator = context.coordinator] in coordinator?.scheduleLayout() }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SelectionPDFView, context: Context) {
        context.coordinator.configure(view, pageDocument: pageDocument, identity: identity, anchor: anchor,
                                      nightReading: nightReading, command: command)
    }

    static func dismantleNSView(_ nsView: SelectionPDFView, coordinator: Coordinator) {
        coordinator.layoutTask?.cancel()
        coordinator.reader = nil
        nsView.onViewportChanged = nil
        nsView.stopInteractionMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var reader: SelectionPDFView?
        var layoutTask: Task<Void, Never>?
        private var loadedDocument: PinnedPageDocument?
        private var loadedIdentity: String?
        private var lastAnchor: SourceAnchor?
        private var pendingAnchor: SourceAnchor?
        private var lastCommand: UUID?
        private var lastViewport = NSSize.zero
        private enum FitMode { case width, page, manual }
        private var fitMode = FitMode.width

        func configure(_ view: SelectionPDFView, pageDocument: PinnedPageDocument, identity: String, anchor: SourceAnchor,
                       nightReading: Bool, command: ReaderCommand?) {
            reader = view
            if loadedIdentity != identity || loadedDocument !== pageDocument {
                loadedDocument = pageDocument
                pageDocument.documentDelegate.nightState.isEnabled = nightReading
                view.document = pageDocument.document
                loadedIdentity = identity
                lastAnchor = nil
                lastViewport = .zero
                fitMode = .width
            }
            view.setNightReading(nightReading)
            if lastAnchor != anchor {
                lastAnchor = anchor
                pendingAnchor = anchor
            }
            if let command, command.token != lastCommand {
                lastCommand = command.token
                switch command.action {
                case .zoomIn: fitMode = .manual; setScale(view.scaleFactor * 1.2)
                case .zoomOut: fitMode = .manual; setScale(view.scaleFactor / 1.2)
                case .actualSize: fitMode = .manual; setScale(1)
                case .fitWidth: fitMode = .width; lastViewport = .zero
                case .fitPage: fitMode = .page; lastViewport = .zero
                default: break
                }
            }
            scheduleLayout()
        }

        func scheduleLayout() {
            layoutTask?.cancel()
            layoutTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.fitAndLocate()
            }
        }

        private func setScale(_ value: CGFloat) {
            guard let reader else { return }
            let destination = reader.currentDestination
            reader.autoScales = false
            let scale = min(max(value, reader.minScaleFactor), reader.maxScaleFactor)
            if abs(reader.scaleFactor - scale) > 0.0001 { reader.scaleFactor = scale }
            if let destination { reader.go(to: destination) }
        }

        private func fitAndLocate() {
            guard let reader, let page = reader.document?.page(at: 0) else { return }
            let viewport = reader.documentView?.enclosingScrollView?.contentView.frame.size ?? reader.bounds.size
            guard viewport.width > 40, viewport.height > 40 else { return }
            if fitMode != .manual, viewport != lastViewport {
                lastViewport = viewport
                let size = page.bounds(for: reader.displayBox).applying(page.transform(for: reader.displayBox)).size
                if size.width > 0, size.height > 0 {
                    let width = max(1, viewport.width - 12) / size.width
                    let height = max(1, viewport.height - 12) / size.height
                    setScale(fitMode == .width ? width : min(width, height))
                }
            }
            if let anchor = pendingAnchor {
                pendingAnchor = nil
                if let first = anchor.rects.first {
                    let region = anchor.rects.dropFirst().reduce(
                        CGRect(x: first.x, y: first.y, width: first.width, height: first.height)
                    ) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
                    reader.go(to: region.insetBy(dx: -12, dy: -20), on: page)
                    reader.flash(page: page, rectangles: anchor.rects.map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    })
                } else { reader.go(to: page) }
            }
        }
    }
}
