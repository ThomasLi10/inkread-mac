import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InkReadCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var navigationWidth: CGFloat = 238
    @State private var inspectorWidth: CGFloat = 390
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if model.showNavigation {
                        navigation.frame(width: navigationWidth)
                        PaneDivider(width: $navigationWidth, limits: 190...300)
                    }
                    reader.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    if model.showInspector {
                        PaneDivider(width: $inspectorWidth, limits: 330...max(330, min(560, geometry.size.width - (model.showNavigation ? navigationWidth : 0) - 430)), reversed: true)
                        ResearchInspector(model: model).frame(width: inspectorWidth)
                    }
                }
                .onChange(of: geometry.size.width) { _, width in
                    inspectorWidth = min(inspectorWidth, max(330, width - (model.showNavigation ? navigationWidth : 0) - 430))
                }
            }
            statusBar
        }
        .background(Color.paper)
        .toolbar { toolbar }
        .overlay(alignment: .top) {
            if model.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.16).ignoresSafeArea().onTapGesture { model.showCommandPalette = false }
                    CommandPalette(commands: commands) { model.showCommandPalette = false }.padding(.top, 72)
                }
            }
        }
        .onChange(of: model.selectedBookID) { _, _ in model.restoreSelection() }
        .onChange(of: model.showPDFSearch) { _, show in
            if show { DispatchQueue.main.async { searchFocused = true; model.showPDFSearch = false } }
        }
        .alert("需要处理", isPresented: Binding(get: { !CommandLine.arguments.contains("--smoke-test") && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { !CommandLine.arguments.contains("--smoke-test") && model.showNoteEditor }, set: { model.showNoteEditor = $0 })) { NoteEditor(model: model) }
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: importDrop)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showNavigation.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("显示或隐藏导航  ⇧⌘L").accessibilityLabel("切换导航栏")
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed").foregroundStyle(Color.accent).font(.system(size: 12))
                Text(model.selectedBook?.title ?? "墨读 InkRead").font(.system(size: 12, weight: .medium)).lineLimit(1)
            }.frame(maxWidth: 460)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.openPDFSearch() } label: { Image(systemName: "magnifyingglass") }
                .help("查找 PDF 原文  ⌘F").disabled(model.selectedBook == nil)
            Button { model.showCommandPalette.toggle() } label: {
                HStack(spacing: 5) { Image(systemName: "command"); Text("K").font(.system(size: 11, design: .monospaced)) }
            }.help("命令面板  ⌘K").accessibilityLabel("命令面板")
            Menu {
                Picker("应用外观", selection: $model.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }
                Divider()
                Toggle("深色时反转 PDF 颜色", isOn: $model.invertPDFInDarkMode)
            } label: { Image(systemName: model.appearanceMode.symbol) }
                .help("外观：" + model.appearanceMode.title).accessibilityLabel("外观")
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("显示或隐藏讨论与笔记  ⇧⌘B").accessibilityLabel("切换讨论面板")
            Menu {
                Button("导入 PDF…", action: model.choosePDFs).disabled(model.isBusy)
                Button("导出本书笔记…", action: model.exportNotes).disabled(model.selectedBook == nil)
                if let book = model.selectedBook {
                    Button("重命名书籍…") { model.renameBook(book) }.disabled(model.isBusy)
                    Button("在 Finder 中显示 PDF") {
                        if let url = model.store?.pdfURL(for: book) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                Divider()
                SettingsLink { Text("设置…") }
            } label: { Image(systemName: "ellipsis.circle") }.help("书籍与设置").accessibilityLabel("更多操作")
        }
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                navigationTab("书库", icon: "books.vertical", index: 0)
                navigationTab("目录", icon: "list.bullet.indent", index: 1)
                navigationTab("查找", icon: "text.magnifyingglass", index: 2)
            }.padding(.horizontal, 8).frame(height: 47)
            WorkbenchHairline()
            if model.navigationTab == 0 || model.selectedBook == nil { library }
            else if model.navigationTab == 1 { outline }
            else { search }
        }.background(Color.workbenchSidebar)
    }

    private func navigationTab(_ title: String, icon: String, index: Int) -> some View {
        Button { model.navigationTab = index; if index == 2 { searchFocused = true } } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 11)); Text(title).font(.system(size: 12, weight: model.navigationTab == index ? .semibold : .regular)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(model.navigationTab == index ? Color.accent : .clear).frame(height: 2)
            }.foregroundStyle(model.navigationTab == index ? Color.primary : .secondary).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var library: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: "书名或标签", text: $model.librarySearch).padding(12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.books) { book in
                        Button { model.selectedBookID = book.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.richtext").font(.system(size: 23, weight: .light)).foregroundStyle(Color.accent)
                                    .frame(width: 30, height: 40)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        Text("\(book.currentPage + 1) / \(book.pageCount)").font(.system(size: 10, design: .monospaced))
                                        Text("页").font(.system(size: 10))
                                    }.foregroundStyle(.secondary)
                                    GeometryReader { g in
                                        Capsule().fill(Color.secondary.opacity(0.13)).overlay(alignment: .leading) {
                                            Capsule().fill(Color.accent.opacity(0.65)).frame(width: max(2, g.size.width * Double(book.currentPage + 1) / Double(max(1, book.pageCount))))
                                        }
                                    }.frame(height: 2)
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedBookID == book.id ? Color.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.isBusy)
                            .contextMenu {
                                Button("重命名书籍…") { model.renameBook(book) }
                                Button("在 Finder 中显示 PDF") {
                                    if let url = model.store?.pdfURL(for: book) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                    }
                    if model.books.isEmpty {
                        Text(model.librarySearch.isEmpty ? "将 PDF 拖到这里" : "没有匹配的书籍").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 36)
                    }
                }.padding(.horizontal, 8)
            }
            WorkbenchHairline()
            Button(action: model.choosePDFs) {
                HStack { Image(systemName: "plus"); Text("导入 PDF"); Spacer(); Text("⌘O").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                    .font(.system(size: 12)).padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.isBusy)
        }
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONTENTS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5)
                Spacer()
                Text("\(model.outline.count)").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 15)
            if model.outline.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("此 PDF 没有内置目录").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("查找原文") { model.openPDFSearch() }.buttonStyle(.link).font(.system(size: 12))
                }.padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.outline) { item in
                                Button { model.navigate(to: item.pageIndex) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(item.title).font(.system(size: 12, weight: item.depth == 0 ? .medium : .regular)).lineLimit(3)
                                        Spacer(minLength: 3)
                                        Text("\(item.pageIndex + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    }.padding(.leading, 10 + CGFloat(min(item.depth, 3)) * 11).padding(.trailing, 10).padding(.vertical, 9)
                                        .foregroundStyle(model.currentChapter?.id == item.id ? Color.accent : Color.primary)
                                        .background(model.currentChapter?.id == item.id ? Color.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).id(item.id)
                            }
                        }.padding(.horizontal, 7).padding(.bottom, 12)
                    }
                    .onAppear { if let id = model.currentChapter?.id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private var search: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("查找 PDF 原文", text: $model.pdfSearchQuery).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { model.performReader(.nextMatch) }
                if !model.pdfSearchQuery.isEmpty {
                    Button { model.pdfSearchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("清除原文查找")
                }
            }.font(.system(size: 12)).padding(9).background(Color.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).padding(12)
            if !model.pdfSearchQuery.isEmpty {
                HStack {
                    Text(model.pdfSearching ? "查找中 · \(model.pdfSearchHits.count) 处" : model.pdfSearchHits.count >= 200 ? "前 200 处匹配" : "\(model.pdfSearchHits.count) 处匹配").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    WorkbenchIcon("上一处匹配", symbol: "chevron.up") { model.performReader(.previousMatch) }
                    WorkbenchIcon("下一处匹配", symbol: "chevron.down") { model.performReader(.nextMatch) }
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            WorkbenchHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.pdfSearchHits) { hit in
                        Button { model.readerJump = ReaderJump(pageIndex: hit.pageIndex, rects: hit.rects) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("PDF · \(hit.pageIndex + 1)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accent)
                                Text(hit.text).font(.system(size: 11.5)).lineSpacing(3).lineLimit(4).foregroundStyle(.secondary)
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        WorkbenchHairline().padding(.horizontal, 13)
                    }
                    if model.pdfSearchQuery.isEmpty {
                        Text("在本书原文中查找\n⌘G 跳到下一处匹配").font(.system(size: 12)).lineSpacing(6).foregroundStyle(.tertiary).padding(16)
                    }
                }
            }
        }
    }

    @ViewBuilder private var reader: some View {
        if let book = model.selectedBook, let store = model.store {
            VStack(spacing: 0) {
                readerToolbar(book)
                WorkbenchHairline()
                ZStack(alignment: .bottom) {
                    PDFReaderView(url: store.pdfURL(for: book), captureRegion: model.captureRegion, jump: model.readerJump,
                                  onSelection: model.receiveSelection, onPageChanged: model.recordPage, highlights: sourceHighlights,
                                  nightReading: colorScheme == .dark && model.invertPDFInDarkMode, command: model.readerCommand,
                                  onMetrics: { model.readerMetrics = $0 }, onSearchResults: { model.pdfSearchHits = $0 }, onSearchStatus: { model.pdfSearching = $0 }).id(book.id)
                    if model.captureRegion {
                        VStack { Label("拖动框选图表或公式", systemImage: "cursorarrow.square").font(.system(size: 12)).padding(.horizontal, 13).padding(.vertical, 9)
                                .background(.regularMaterial, in: Capsule()).padding(.top, 15); Spacer() }.allowsHitTesting(false)
                    }
                    if let selection = model.selection { selectionBar(selection).padding(16) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "book.pages").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(Color.accent)
                VStack(alignment: .leading, spacing: 10) {
                    Text("墨读").font(.system(size: 30, weight: .medium))
                    Text("阅读、追问，留下理解。").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Button(action: model.choosePDFs) { Label("导入 PDF", systemImage: "plus").padding(.horizontal, 9).padding(.vertical, 4) }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent).disabled(model.isBusy)
                Text("也可将文件拖入窗口  ·  ⌘O 导入  ·  ⌘K 命令").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.workbenchCanvas)
        }
    }

    private func readerToolbar(_ book: Book) -> some View {
        HStack(spacing: 5) {
            WorkbenchIcon("返回上一阅读位置", symbol: "arrow.left", enabled: model.readerMetrics?.canGoBack ?? false) { model.performReader(.back) }
            WorkbenchIcon("前进到下一阅读位置", symbol: "arrow.right", enabled: model.readerMetrics?.canGoForward ?? false) { model.performReader(.forward) }
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1, height: 14).padding(.horizontal, 4)
            WorkbenchIcon("上一页  ⌘↑", symbol: "chevron.up") { model.turnPage(-1) }
            TextField("页码", text: $model.pageNumber).font(.system(size: 11, weight: .medium, design: .monospaced)).textFieldStyle(.plain)
                .multilineTextAlignment(.center).frame(width: 35, height: 23).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4)).onSubmit(model.goToPage)
                .accessibilityLabel("PDF 页码")
            Text("/ \(book.pageCount)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).fixedSize()
            WorkbenchIcon("下一页  ⌘↓", symbol: "chevron.down") { model.turnPage(1) }
            Spacer(minLength: 3)
            WorkbenchIcon("缩小  ⌘−", symbol: "minus") { model.performReader(.zoomOut) }
            Menu {
                Button("实际大小  100%") { model.performReader(.actualSize) }
                Button("适合宽度") { model.performReader(.fitWidth) }
                Button("整页显示") { model.performReader(.fitPage) }
            } label: { Text(model.zoomLabel).font(.system(size: 10.5, design: .monospaced)).frame(width: 44) }.menuStyle(.borderlessButton).fixedSize().help("阅读缩放")
            WorkbenchIcon("放大  ⌘+", symbol: "plus") { model.performReader(.zoomIn) }
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1, height: 14).padding(.horizontal, 4)
            WorkbenchIcon(model.captureRegion ? "取消框选图表" : "框选图表", symbol: "crop", active: model.captureRegion) { model.captureRegion.toggle() }
            WorkbenchIcon(model.focusMode ? "退出专注阅读  ⇧⌘F" : "专注阅读  ⇧⌘F", symbol: model.focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", active: model.focusMode) { model.toggleFocusMode() }
        }.padding(.horizontal, 10).frame(height: 47).background(Color.workbenchChrome)
    }

    private func selectionBar(_ selection: ReaderSelection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selection.imageData == nil ? "text.quote" : "viewfinder").foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(selection.imageData == nil ? "原文" : "图表") · PDF \(selection.pageIndex + 1)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Text(selection.text.isEmpty ? "已选择图表范围" : selection.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { model.startDiscussion() } label: { Text("讨论此处").font(.system(size: 11, weight: .medium)).padding(.horizontal, 4) }
                .buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent).controlSize(.small).disabled(model.isBusy)
            WorkbenchIcon("写选段笔记", symbol: "square.and.pencil") { model.openNoteEditor() }
            WorkbenchIcon("清除选区", symbol: "xmark") { model.clearReaderSelection() }
        }.padding(11).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }

    private var sourceHighlights: [ReaderHighlight] {
        let anchors = (model.store?.notes.filter { $0.documentID == model.selectedBookID } ?? []).flatMap(\.anchors) + model.discussions.compactMap(\.anchor)
        var seen = Set<UUID>()
        return anchors.filter { seen.insert($0.id).inserted }.map {
            ReaderHighlight(id: $0.id, pageIndex: $0.pageIndex, rects: $0.rects,
                            colorHex: $0.imageRelativePath == nil ? "F8CE46" : "3E8A80", isRegion: $0.imageRelativePath != nil)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            WorkbenchHairline()
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                else { Image(systemName: "internaldrive").font(.system(size: 9)).foregroundStyle(.tertiary) }
                Text(model.isGenerating ? model.activity : model.isImporting ? "建立原文索引…" : model.notice.isEmpty ? "本地书库 · 自动保存" : model.notice)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 12)
                if let chapter = model.currentChapter { Text(chapter.title).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                if let book = model.selectedBook {
                    Text("\(model.pageNumber) / \(book.pageCount)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button { model.showCommandPalette = true } label: { Text("⌘ K").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary) }.buttonStyle(.plain).help("打开命令面板")
            }.padding(.horizontal, 13).frame(height: 24).background(Color.workbenchChrome)
        }
    }

    private var commands: [WorkbenchCommand] {
        var items = [
            WorkbenchCommand(id: "import", title: "导入 PDF…", subtitle: "打开一本书或论文 Import", systemImage: "plus", shortcut: "⌘O", perform: model.choosePDFs),
            WorkbenchCommand(id: "search", title: "查找 PDF 原文", subtitle: "全文搜索 Find Search", systemImage: "magnifyingglass", shortcut: "⌘F", perform: model.openPDFSearch),
            WorkbenchCommand(id: "outline", title: "打开目录", subtitle: "章节导航 Contents Outline", systemImage: "list.bullet.indent", shortcut: "⇧⌘O", perform: model.openOutline),
            WorkbenchCommand(id: "focus", title: model.focusMode ? "退出专注阅读" : "进入专注阅读", subtitle: "收起两侧面板 Focus", systemImage: "viewfinder", shortcut: "⇧⌘F", perform: model.toggleFocusMode),
            WorkbenchCommand(id: "library", title: "打开书库", subtitle: "切换书籍 Library", systemImage: "books.vertical", shortcut: nil) { model.showNavigation = true; model.navigationTab = 0 },
            WorkbenchCommand(id: "inspector", title: "切换讨论与笔记面板", subtitle: "显示或隐藏 Inspector", systemImage: "sidebar.right", shortcut: "⇧⌘B") { model.showInspector.toggle() }
        ]
        if model.selectedBook != nil {
            items += [
                WorkbenchCommand(id: "discussion", title: "开始新讨论", subtitle: "围绕当前选段或整本书追问 New discussion", systemImage: "bubble.left.and.bubble.right", shortcut: "⌘N") { model.startDiscussion() },
                WorkbenchCommand(id: "notes", title: "打开本书笔记", subtitle: "查看阅读笔记 Notes", systemImage: "note.text", shortcut: nil) { model.showInspector = true; model.rightTab = 1 },
                WorkbenchCommand(id: "note", title: "写阅读笔记", subtitle: "保存当前选段或讨论结论", systemImage: "square.and.pencil", shortcut: "⇧⌘S") { model.openNoteEditor() },
                WorkbenchCommand(id: "fitWidth", title: "PDF 适合宽度", subtitle: "随阅读区域宽度调整 Fit width", systemImage: "arrow.left.and.right", shortcut: "⌘1") { model.performReader(.fitWidth) },
                WorkbenchCommand(id: "fitPage", title: "PDF 整页显示", subtitle: "Fit page", systemImage: "doc", shortcut: "⌘2") { model.performReader(.fitPage) },
                WorkbenchCommand(id: "actual", title: "PDF 实际大小", subtitle: "100% Actual size", systemImage: "1.magnifyingglass", shortcut: "⌘0") { model.performReader(.actualSize) },
                WorkbenchCommand(id: "export", title: "导出本书笔记…", subtitle: "Markdown Export", systemImage: "square.and.arrow.up", shortcut: "⇧⌘E", perform: model.exportNotes)
            ]
        }
        items += AppearanceMode.allCases.map { mode in WorkbenchCommand(id: "theme-" + mode.rawValue, title: "外观：" + mode.title, subtitle: "Theme Appearance", systemImage: mode.symbol, shortcut: nil) { model.appearanceMode = mode } }
        return items.filter { !model.isBusy || !["import", "discussion"].contains($0.id) }
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            model.importPDFs(urls)
        }
        return !providers.isEmpty
    }
}
