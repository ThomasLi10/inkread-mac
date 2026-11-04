import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InkReadCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 205, idealWidth: 230, maxWidth: 300)
            reader.frame(minWidth: 480, maxWidth: .infinity)
            inspector.frame(minWidth: 340, idealWidth: 410, maxWidth: 580)
        }
        .background(Color.paper)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed.fill").foregroundStyle(Color.accent)
                    Text("墨读").font(.headline)
                }
            }
            ToolbarItemGroup {
                Button(action: model.choosePDFs) { Label("导入 PDF", systemImage: "plus") }.disabled(model.isBusy)
                Button(action: model.exportNotes) { Label("导出笔记", systemImage: "square.and.arrow.up") }.disabled(model.selectedBook == nil)
            }
        }
        .onChange(of: model.selectedBookID) { _, _ in model.restoreSelection() }
        .alert("需要处理", isPresented: Binding(get: { !CommandLine.arguments.contains("--smoke-test") && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { !CommandLine.arguments.contains("--smoke-test") && model.showNoteEditor }, set: { model.showNoteEditor = $0 })) { NoteEditor(model: model) }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("我的书库").font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.store?.books.count ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 14)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索书名或标签", text: $model.librarySearch).textFieldStyle(.plain)
            }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 14)
            if model.books.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.librarySearch.isEmpty ? "让每次阅读留下理解" : "没有找到书籍").font(.callout).foregroundStyle(.secondary)
                    if model.librarySearch.isEmpty { Button("导入第一份 PDF…", action: model.choosePDFs).buttonStyle(.link) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List(selection: $model.selectedBookID) {
                    ForEach(model.books) { book in
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5).fill(Color.accent.opacity(0.10))
                                Image(systemName: "doc.richtext").font(.title2).foregroundStyle(Color.accent)
                            }.frame(width: 36, height: 46)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(book.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text("\(book.currentPage + 1) / \(book.pageCount) 页").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(book.id)
                            .contextMenu {
                                Button("重命名书籍…") { model.renameBook(book) }
                                Button("在 Finder 中显示 PDF") {
                                    if let url = model.store?.pdfURL(for: book) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                    }
                }.listStyle(.sidebar).disabled(model.isBusy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("本地书库 · 自动保存", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                Text(model.isImporting ? "正在建立原文索引…" : "可将 PDF 拖入窗口导入")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
    }

    @ViewBuilder private var reader: some View {
        if let book = model.selectedBook, let store = model.store {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(book.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.turnPage(-1) } label: { Image(systemName: "chevron.up") }.help("上一页")
                    TextField("页码", text: $model.pageNumber).frame(width: 40).multilineTextAlignment(.center).onSubmit(model.goToPage)
                    Text("/ \(book.pageCount)").font(.caption).foregroundStyle(.secondary)
                    Button { model.turnPage(1) } label: { Image(systemName: "chevron.down") }.help("下一页")
                    Divider().frame(height: 18)
                    Button {
                        model.captureRegion.toggle()
                    } label: { Label(model.captureRegion ? "取消框选" : "框选图表", systemImage: "crop") }
                    .tint(model.captureRegion ? Color.accent : nil)
                }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ZStack(alignment: .top) {
                    PDFReaderView(url: store.pdfURL(for: book), captureRegion: model.captureRegion, jump: model.readerJump,
                                  onSelection: model.receiveSelection, onPageChanged: model.recordPage,
                                  highlights: sourceHighlights).id(book.id)
                    if model.captureRegion {
                        Label("在一页内拖动，框住想讨论的图表或公式", systemImage: "cursorarrow.square")
                            .font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule()).padding(.top, 14).allowsHitTesting(false)
                    }
                }
                Divider()
                if let selection = model.selection {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(selection.imageData == nil ? "已选择原文" : "已框选图表", systemImage: selection.imageData == nil ? "text.quote" : "photo")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.accent)
                            Text("PDF 第 \(selection.pageIndex + 1) 页").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { model.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("清除当前选区")
                        }
                        if !selection.text.isEmpty { Text(selection.text).font(.callout).lineLimit(2).textSelection(.enabled) }
                        HStack {
                            Text("选段与页内位置将随讨论保存").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button { model.startDiscussion() } label: { Label("讨论此处", systemImage: "bubble.left.and.bubble.right") }
                                .buttonStyle(.borderedProminent).disabled(model.isBusy)
                        }
                    }.padding(14).background(Color.accent.opacity(0.045))
                } else {
                    HStack {
                        Label("选中文字，或框选图表，与 Codex 一起读", systemImage: "cursorarrow.rays").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.isImporting { ProgressView().controlSize(.small) }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: "book.pages").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Color.accent)
                Text("把读过的，变成自己的").font(.system(size: 25, weight: .medium, design: .serif))
                Text("导入书籍或论文，围绕一段话、一张图展开讨论。\n原文、思考与结论，都留在同一个地方。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(6)
                Button(action: model.choosePDFs) { Label("导入 PDF 开始阅读", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.paper)
        }
    }

    private var sourceHighlights: [ReaderHighlight] {
        let anchors = model.notes.flatMap(\.anchors) + model.discussions.compactMap(\.anchor)
        var seen = Set<UUID>()
        return anchors.filter { seen.insert($0.id).inserted }.map {
            ReaderHighlight(id: $0.id, pageIndex: $0.pageIndex, rects: $0.rects,
                            colorHex: $0.imageRelativePath == nil ? "F8CE46" : "3E8A80",
                            isRegion: $0.imageRelativePath != nil)
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if let reply = model.unsavedReply {
                VStack(alignment: .leading, spacing: 8) {
                    Text("上次回复未能写入磁盘，内容暂时保留在这里").font(.caption).foregroundStyle(.orange)
                    Text(reply).font(.caption).lineLimit(3).textSelection(.enabled)
                    Button("复制完整回复") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reply, forType: .string)
                    }.buttonStyle(.link).font(.caption)
                }.padding(14)
                Divider()
            }
            HStack {
                Picker("内容", selection: $model.rightTab) {
                    Text("讨论").tag(0)
                    Text("笔记 \(model.notes.count)").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                Button { model.openNoteEditor() } label: { Image(systemName: "square.and.pencil") }
                    .help("写笔记").disabled(model.selectedBook == nil)
            }.padding(14)
            Divider()
            if model.rightTab == 0 { discussionPane } else { notesPane }
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.isGenerating ? Color.orange : Color.accent).frame(width: 6, height: 6)
                Text(model.isGenerating ? model.activity : (model.notice.isEmpty ? "讨论通过本机 Codex 运行" : model.notice))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }.background(Color.paper)
    }

    private var discussionPane: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(model.discussions) { discussion in
                        Button(discussion.title) { model.selectedDiscussionID = discussion.id }
                    }
                } label: { Label("历史讨论 \(model.discussions.count)", systemImage: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.isGenerating || model.discussions.isEmpty)
                Spacer()
                Button { model.startDiscussion(useSelection: false) } label: { Label("新讨论", systemImage: "plus.bubble") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accent).disabled(model.selectedBook == nil || model.isBusy)
            }.padding(14)
            if let discussion = model.currentDiscussion {
                if let anchor = discussion.anchor { sourceCard(anchor).padding(.horizontal, 14).padding(.bottom, 10) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(discussion.messages) { message in messageView(message) }
                            if discussion.messages.isEmpty { discussionHint }
                            Color.clear.frame(height: 1).id("conversation-bottom")
                        }.padding(16)
                    }
                    .onChange(of: model.streamingText) { _, _ in proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                    .onChange(of: discussion.messages.count) { _, _ in proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            } else {
                discussionHint.frame(maxHeight: .infinity).padding(24)
            }
            composer
        }
    }

    private var discussionHint: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkle").font(.title2).foregroundStyle(Color.accent)
            Text("从一个疑问开始").font(.title3.weight(.medium))
            Text("选中原文后点“讨论此处”，也可以直接向这本书提问。每次讨论和引用都会自动保存。")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            if model.selectedBook != nil {
                ForEach(["用直观的例子解释这段内容", "这张图的结论和前提是什么？", "帮我梳理这一页的关键概念"], id: \.self) { question in
                    Button(question) { model.prompt = question }.buttonStyle(.link).font(.caption)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(message.role == .user ? "我" : "Codex", systemImage: message.role == .user ? "person.crop.circle" : "sparkle")
                    .font(.caption.weight(.semibold)).foregroundStyle(message.role == .user ? .secondary : Color.accent)
                Spacer()
                if message.status == .failed || message.status == .interrupted {
                    Text(message.status == .failed ? "未完成" : "已停止").font(.caption2).foregroundStyle(.orange)
                }
            }
            let body = model.messageBody(message)
            if body.isEmpty && message.status == .inProgress {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在思考…").foregroundStyle(.secondary).font(.callout) }
            } else {
                Text(.init(body)).font(.system(size: 14)).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
            }
            if message.role == .assistant && message.status == .completed && !message.body.isEmpty {
                HStack {
                    Button { model.openNoteEditor(answer: message) } label: { Label("存为笔记", systemImage: "bookmark") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.body, forType: .string)
                    } label: { Label("复制", systemImage: "doc.on.doc") }
                }.buttonStyle(.link).font(.caption)
            }
        }.padding(12).background(message.role == .user ? Color.accent.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextEditor(text: $model.prompt).font(.system(size: 14)).scrollContentBackground(.hidden)
                .frame(minHeight: 65, idealHeight: 78, maxHeight: 110)
                .overlay(alignment: .topLeading) {
                    if model.prompt.isEmpty { Text("写下你的问题…").foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 4).allowsHitTesting(false) }
                }
                .disabled(model.isGenerating || model.selectedBook == nil)
            HStack {
                Text("⌘ Return 发送").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if model.isGenerating {
                    Button("停止", action: model.cancelResponse).buttonStyle(.bordered)
                } else {
                    Button(action: model.sendMessage) { Label("发送", systemImage: "arrow.up") }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.selectedBook == nil || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isImporting)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).padding(14)
    }

    private func sourceCard(_ anchor: SourceAnchor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("PDF 第 \(anchor.pageIndex + 1) 页", systemImage: anchor.imageRelativePath == nil ? "text.quote" : "photo")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accent)
                Spacer()
                Button("回到原文") { model.jumpTo(anchor) }.buttonStyle(.link).font(.caption)
            }
            if let path = anchor.imageRelativePath, let url = model.store?.assetURL(relativePath: path), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 170).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if let text = anchor.selectedText, !text.isEmpty { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var notesPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索本书笔记", text: $model.noteSearch).textFieldStyle(.plain)
            }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7)).padding(14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "note.text").font(.title).foregroundStyle(.tertiary)
                            Text("理解，值得留下来").font(.headline)
                            Text("把 Codex 的回答存成笔记，再加入自己的理解。笔记会保留原文位置。")
                                .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                        }.padding(10)
                    }
                    ForEach(model.notes) { note in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                Text(note.title).font(.headline)
                                Spacer()
                                Menu {
                                    Button("编辑笔记") { model.openNoteEditor(existing: note) }
                                    Button("删除笔记", role: .destructive) { model.deleteNote(note) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            Text(.init(note.body)).font(.callout).textSelection(.enabled).lineSpacing(4).lineLimit(12)
                            ForEach(note.anchors) { anchor in sourceCard(anchor) }
                            HStack {
                                Text(note.updatedAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                                if let id = note.discussionID {
                                    Button("查看讨论") { model.selectedDiscussionID = id; model.rightTab = 0 }.font(.caption).buttonStyle(.link)
                                }
                                Button("编辑") { model.openNoteEditor(existing: note) }.font(.caption).buttonStyle(.link)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }
}

struct NoteEditor: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.editingNote == nil ? "保存阅读笔记" : "编辑阅读笔记").font(.title2.weight(.semibold))
            TextField("笔记标题", text: $model.noteTitle).textFieldStyle(.roundedBorder)
            TextEditor(text: $model.noteBody).font(.system(size: 14)).lineSpacing(5)
                .border(Color.secondary.opacity(0.2)).frame(minHeight: 300)
            HStack {
                Text("原文引用随笔记一起保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.showNoteEditor = false }.keyboardShortcut(.cancelAction)
                Button("保存", action: model.saveNote).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 650, height: 500)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("本地 Codex") {
                TextField("可执行文件路径（留空自动查找）", text: $model.codexPath)
                HStack {
                    Button("选择 Codex…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { model.codexPath = url.path; model.applyCodexPath() }
                    }
                    Button("应用设置", action: model.applyCodexPath)
                }
                Text("复用 Codex 自己的登录。提交的选段与图表会发往所用模型服务；阅读副本、笔记和讨论保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("书库") {
                Button("在 Finder 中打开本地书库") {
                    if let root = model.store?.rootURL { NSWorkspace.shared.open(root) }
                }
            }
        }.formStyle(.grouped)
    }
}
