import SwiftUI
import AppKit
import InkReadCore

/// The reading workspace's compact discussion and notes column. All mutations go
/// through AppModel; choosing another passage never changes a thread implicitly.
struct ResearchInspector: View {
    @ObservedObject var model: AppModel
    @State private var historyExpanded = false
    @State private var historyQuery = ""
    @State private var sourceExpanded = false
    @State private var expandedNoteIDs = Set<UUID>()
    @State private var unsavedExpanded = true
    @State private var followsLatest = true
    @State private var lastScrollOffset: CGFloat = 0
    @State private var composerWidth: CGFloat = 320
    @State private var availableHeight: CGFloat = 800
    @FocusState private var promptFocused: Bool

    private let conversationSpace = "InkReadResearchConversation"
    private let bottomID = "InkReadResearchConversationBottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            if model.rightTab == 0 {
                history
                if let discussion = model.currentDiscussion {
                    activeContext(discussion)
                    separator
                }
                conversation.frame(minHeight: availableHeight < 740 ? 100 : 140)
                composer
            } else if model.rightTab == 1 {
                notes
            } else {
                KnowledgePanel(model: model)
            }
            connectionFooter
        }
        .background(Color.paper)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { availableHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in availableHeight = height }
        })
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "inkread-page" else { return .systemAction }
            guard let value = url.host, let page = Int(value),
                  page > 0, page <= (model.selectedBook?.pageCount ?? 0) else { return .discarded }
            model.navigate(to: page - 1)
            return .handled
        })
        .onChange(of: model.selectedDiscussionID) { _, _ in
            if model.currentDiscussion?.messages.isEmpty == true { promptFocused = true }
        }
        .onChange(of: model.focusComposerToken) { _, _ in
            model.rightTab = 0
            DispatchQueue.main.async { promptFocused = true }
        }
        .onChange(of: model.selectedBookID) { _, _ in
            historyQuery = ""
            sourceExpanded = false
            followsLatest = true
            lastScrollOffset = 0
        }
    }

    private var totalNotes: Int {
        model.store?.notes.filter { $0.documentID == model.selectedBookID }.count ?? 0
    }

    private var historyResults: [Discussion] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.discussions.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || ($0.anchor?.selectedText?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.messages.contains { $0.body.localizedCaseInsensitiveContains(query) }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 0.5)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            tab("讨论", count: model.discussions.count, value: 0)
            tab("笔记", count: totalNotes, value: 1)
            tab("整理", count: nil, value: 2)
            Spacer(minLength: 0)
            if model.rightTab == 0 {
                Button {
                    model.startDiscussion(useSelection: false)
                    promptFocused = true
                } label: {
                    Label("新讨论", systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(model.selectedBook == nil || model.isBusy)
                    .help("创建关于本书的新讨论")
            } else if model.rightTab == 1 {
                Button { model.openNoteEditor() } label: {
                    Label("写笔记", systemImage: "square.and.pencil").font(.system(size: 11.5, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.selectedBook == nil || model.isBusy)
            } else {
                Menu {
                    Button("新增疑问") { model.openQuestionEditor() }
                    Button("新增术语") { model.openTermEditor() }
                    Button("固定当前页") { model.pinCurrentPage() }
                    Divider()
                    Button("编辑书籍标签") { model.openTagsEditor() }
                } label: { Image(systemName: "plus").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                    .disabled(model.selectedBook == nil || model.isBusy).help("添加知识记录")
            }
        }
        .padding(.horizontal, 18).frame(height: 47)
    }

    private func tab(_ title: String, count: Int?, value: Int) -> some View {
        Button { model.rightTab = value } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13, weight: model.rightTab == value ? .semibold : .regular))
                    if let count { Text(String(count)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary) }
                }.frame(maxHeight: .infinity)
                Rectangle().fill(model.rightTab == value ? Color.accent : .clear).frame(height: 2)
            }
            .foregroundStyle(model.rightTab == value ? Color.primary : .secondary)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(count.map { "\(title)，\($0) 项" } ?? title)
    }

    private var history: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.14)) { historyExpanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 9)
                    Text("讨论记录").font(.system(size: 11.5, weight: .medium))
                    if !historyExpanded, let title = model.currentDiscussion?.title {
                        Text(title).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(String(model.discussions.count)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 33).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if historyExpanded {
                if model.discussions.isEmpty {
                    Text("尚无讨论").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34).padding(.bottom, 12)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
                        TextField("查找讨论", text: $historyQuery).font(.system(size: 11.5)).textFieldStyle(.plain)
                        if !historyQuery.isEmpty {
                            Button { historyQuery = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("清除搜索")
                        }
                    }.padding(.horizontal, 18).padding(.bottom, 7)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(historyResults) { discussion in historyRow(discussion) }
                            if historyResults.isEmpty {
                                Text("没有匹配的讨论").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                        }.padding(.horizontal, 9).padding(.bottom, 7)
                    }
                    .frame(maxHeight: CGFloat(min(max(historyResults.count, 1), 3)) * 48 + 7)
                }
            }
            separator
        }
    }

    private func historyRow(_ discussion: Discussion) -> some View {
        let selected = discussion.id == model.selectedDiscussionID
        let answers = discussion.messages.filter { $0.role == .assistant && $0.status == .completed }.count
        return Button {
            model.selectedDiscussionID = discussion.id
            sourceExpanded = false
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1).fill(selected ? Color.accent : .clear).frame(width: 2, height: 25)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(discussion.title).font(.system(size: 12, weight: selected ? .medium : .regular))
                            .foregroundStyle(.primary).lineLimit(1)
                        if let status = model.questions.first(where: { $0.discussionID == discussion.id })?.status {
                            Image(systemName: questionIcon(status)).font(.system(size: 9)).foregroundStyle(.secondary)
                                .help(questionTitle(status))
                        }
                    }
                    HStack(spacing: 7) {
                        Text(discussion.anchor.map { "PDF \($0.pageIndex + 1)" } ?? "本书")
                        Text("·")
                        Text("\(answers) 条回答")
                        Spacer(minLength: 4)
                        Text(discussion.updatedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                    }.font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.trailing, 9).padding(.leading, 5).frame(height: 46)
            .background(selected ? Color.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.isBusy)
            .help("打开讨论：\(discussion.title)")
            .contextMenu {
                Button("重命名讨论") {
                    model.selectedDiscussionID = discussion.id
                    model.renameDiscussion()
                }.disabled(model.isBusy)
                Button("加入上下文篮") { model.addDiscussionToContext(discussion) }.disabled(model.isBusy)
                Button("记为疑问") { model.createQuestionFromDiscussion(discussion) }.disabled(model.isBusy)
                questionStatusMenu(discussion)
            }
    }

    private func activeContext(_ discussion: Discussion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(discussion.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("重命名讨论") { model.renameDiscussion() }
                    Button("整段讨论加入上下文") { model.addDiscussionToContext(discussion) }
                    Button("记为疑问") { model.createQuestionFromDiscussion(discussion) }
                    questionStatusMenu(discussion)
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).disabled(model.isBusy)
            }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 2)
            if let anchor = discussion.anchor {
                HStack(spacing: 7) {
                    Button { withAnimation(.easeInOut(duration: 0.14)) { sourceExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: anchor.imageRelativePath == nil ? "text.quote" : "crop")
                            Text("讨论引用 · PDF \(anchor.pageIndex + 1)").fontWeight(.medium)
                            Image(systemName: sourceExpanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { model.jumpTo(anchor) } label: {
                        Label("回到原文", systemImage: "arrow.up.left").font(.system(size: 10.5))
                    }.buttonStyle(.plain).foregroundStyle(Color.accent)
                    Menu {
                        Button("此引用加入上下文") { model.addAnchorToContext(anchor) }
                        Button("固定为参考位置") { model.pinAnchor(anchor) }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).disabled(model.isBusy)
                }.padding(.horizontal, 18).frame(height: 35)
                if sourceExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            if let path = anchor.imageRelativePath, let url = model.store?.assetURL(relativePath: path) {
                                InspectorImagePreview(url: url).frame(maxHeight: 140)
                            }
                            if let quote = anchor.selectedText, !quote.isEmpty {
                                Text(quote).font(.system(size: 12)).lineSpacing(3).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.padding(.horizontal, 18).padding(.bottom, 12)
                    }.frame(maxHeight: 165)
                }
            } else {
                Text("本书讨论 · 可按需添加材料")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 18).padding(.top, 5).padding(.bottom, 10)
            }
        }
    }

    private func questionStatusMenu(_ discussion: Discussion) -> some View {
        Menu("疑问状态") {
            Button(QuestionStatus.open.title) { model.setQuestionStatus(for: discussion, status: .open) }
            Button(QuestionStatus.verify.title) { model.setQuestionStatus(for: discussion, status: .verify) }
            Button(QuestionStatus.resolved.title) { model.setQuestionStatus(for: discussion, status: .resolved) }
        }.disabled(model.isBusy)
    }

    private func questionIcon(_ status: QuestionStatus) -> String {
        switch status {
        case .open: return "questionmark.circle"
        case .verify: return "circle.dotted"
        case .resolved: return "checkmark.circle"
        }
    }

    private func questionTitle(_ status: QuestionStatus) -> String {
        status.title
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let discussion = model.currentDiscussion, !discussion.messages.isEmpty {
                        ForEach(discussion.messages) { message in messageRow(message) }
                    } else {
                        Text(model.selectedBook == nil ? "打开一份 PDF 后开始讨论。" : "输入问题，或选中原文后讨论。")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.top, 9)
                    }
                    if let error = model.lastResponseError, !error.isEmpty, !model.isGenerating {
                        responseFailure(error)
                    }
                    if let unsaved = model.unsavedReply, !unsaved.isEmpty { unsavedReply(unsaved) }
                    Color.clear.frame(height: 1).id(bottomID)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: InspectorScrollPreference.self,
                                value: InspectorScrollMetrics(bottom: geometry.frame(in: .named(conversationSpace)).maxY))
                        })
                }
                .padding(.horizontal, 19).padding(.top, 18).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: InspectorScrollPreference.self, value: InspectorScrollMetrics(contentHeight: geometry.size.height))
                })
            }
            .coordinateSpace(name: conversationSpace)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: InspectorScrollPreference.self, value: InspectorScrollMetrics(viewportHeight: geometry.size.height))
            })
            .onPreferenceChange(InspectorScrollPreference.self) { metrics in
                guard let bottom = metrics.bottom, let content = metrics.contentHeight, let viewport = metrics.viewportHeight else { return }
                let offset = content - bottom
                // Content growth changes content and bottom equally. Only a
                // decreasing offset means the reader deliberately scrolled up.
                if offset < lastScrollOffset - 2, bottom > viewport + 60 { followsLatest = false }
                if bottom <= viewport + 45 { followsLatest = true }
                lastScrollOffset = offset
            }
            .onChange(of: model.streamingText) { _, _ in scrollToLatest(proxy, force: false) }
            .onChange(of: model.currentDiscussion?.messages.count ?? 0) { _, _ in scrollToLatest(proxy, force: false) }
            .onAppear { scrollToLatest(proxy, force: true) }
            .onChange(of: model.selectedDiscussionID) { _, _ in
                followsLatest = true
                lastScrollOffset = 0
                scrollToLatest(proxy, force: true)
            }
            .overlay(alignment: .bottom) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        scrollToLatest(proxy, force: true)
                    } label: {
                        Label("回到最新", systemImage: "arrow.down").font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                    }.buttonStyle(.plain).padding(.bottom, 8)
                }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, force: Bool) {
        guard force || followsLatest else { return }
        DispatchQueue.main.async {
            guard force || followsLatest else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let body = model.messageBody(message)
        return VStack(alignment: .leading, spacing: message.role == .user ? 6 : 11) {
            HStack(spacing: 6) {
                if message.role == .assistant {
                    Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Color.accent)
                }
                Text(message.role == .user ? "我" : "Codex")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(message.createdAt, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if message.status == .failed || message.status == .interrupted {
                    Text(message.status == .failed ? "未完成" : "已停止").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if body.isEmpty && message.status == .inProgress {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("正在准备回答…").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            } else if message.role == .user {
                Text(body).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownMessageView(text: body)
            }
            if message.role == .user {
                SentContextSnapshot(items: message.contextItems, model: model)
            }
            if !body.isEmpty {
                HStack(spacing: 13) {
                    Button { copy(body) } label: { Label("复制", systemImage: "doc.on.doc") }
                    if message.role == .assistant && message.status == .completed {
                        Button { model.openNoteEditor(answer: message) } label: { Label("笔记", systemImage: "bookmark") }
                            .disabled(model.isBusy).help("将这条回答存为笔记")
                    }
                    Button { model.addMessageToContext(message) } label: { Label("加入上下文", systemImage: "tray.and.arrow.down") }
                        .disabled(model.isBusy).help("把这条消息加入待发送的上下文篮")
                    Button { model.forkDiscussion(through: message) } label: { Label("分支", systemImage: "arrow.triangle.branch") }
                        .disabled(model.isBusy || message.status == .inProgress).help("从这条消息开启独立讨论，保留原讨论")
                }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !body.isEmpty { Button("复制内容") { copy(body) } }
            if message.role == .assistant && message.status == .completed && !body.isEmpty {
                Button("存为笔记") { model.openNoteEditor(answer: message) }.disabled(model.isBusy)
            }
            if !body.isEmpty {
                Button("加入上下文篮") { model.addMessageToContext(message) }.disabled(model.isBusy)
                Button("从此处开启分支") { model.forkDiscussion(through: message) }
                    .disabled(model.isBusy || message.status == .inProgress)
            }
        }
    }

    private func responseFailure(_ error: String) -> some View {
        let retryAvailable = model.currentDiscussion?.messages.last.map {
            $0.role == .assistant && ($0.status == .failed || $0.status == .interrupted)
        } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Label("本次回答未完成", systemImage: "exclamationmark.circle")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            Text(error).font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(.secondary)
                .lineLimit(4).textSelection(.enabled)
            HStack {
                Text(retryAvailable ? "原问题和已有回复已保留。" : "草稿仍保留，可调整后再次发送。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if retryAvailable {
                    Button("在新分支重试", action: model.retryLastQuestion)
                        .font(.system(size: 10.5, weight: .medium)).buttonStyle(.plain).foregroundStyle(Color.accent)
                        .disabled(model.isBusy)
                }
            }
        }.padding(.vertical, 9)
    }

    private func unsavedReply(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("待恢复的回复").fontWeight(.medium)
                Spacer()
                Button("复制回复") { copy(body) }.foregroundStyle(Color.accent)
                Button { unsavedExpanded.toggle() } label: { Image(systemName: unsavedExpanded ? "chevron.up" : "chevron.down") }
            }.font(.system(size: 11)).buttonStyle(.plain)
            Text(model.unsavedReplyOrigin).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            if unsavedExpanded { MarkdownMessageView(text: body) }
        }.padding(.top, 9)
        .environment(\.openURL, OpenURLAction { url in
            url.scheme == "inkread-page" ? .discarded : .systemAction
        })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.isGenerating {
                HStack(alignment: .center, spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(model.activity.isEmpty ? "Codex 正在运行…" : model.activity)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2).help(model.activity)
                    Spacer(minLength: 0)
                    if let startedAt = model.responseStartedAt {
                        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                            Text(elapsed(since: startedAt, now: timeline.date))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    Button("停止", action: model.cancelResponse)
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }.padding(.horizontal, 3).padding(.vertical, 3)
            }
            ContextBasketView(model: model, compact: availableHeight < 740)
            if let selection = model.selection {
                HStack(spacing: 6) {
                    Image(systemName: selection.imageData == nil ? "text.quote" : "crop").font(.system(size: 10))
                    Text("选区 · PDF \(selection.pageIndex + 1)").font(.system(size: 10.5))
                    Spacer(minLength: 4)
                    Button("加入材料", action: model.addSelectionToContext)
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.accent)
                        .disabled(model.isBusy).help("只加入上下文篮，不会自动发送")
                    Button {
                        let draft = model.prompt
                        model.startDiscussion()
                        model.prompt = draft
                        promptFocused = true
                    } label: { Text("单独讨论").font(.system(size: 10.5)) }
                        .buttonStyle(.plain).foregroundStyle(Color.accent).disabled(model.isBusy)
                        .help("为当前选区新建讨论，保留已有讨论的引用")
                    Menu {
                        Button("固定为参考位置", action: model.pinSelection)
                        Button("写选区笔记") { model.openNoteEditor() }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 10)) }
                        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).disabled(model.isBusy)
                    Button { model.clearReaderSelection() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("清除当前选区")
                }.foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                preset("解释", text: "请解释当前材料的核心含义，指出关键前提，并引用原文页码。")
                preset("推导", text: "请逐步补全相关公式的推导，说明每一步使用的假设、符号和适用条件。")
                preset("举例", text: "请用一个具体的小例子说明当前材料，再给出一个容易误用的反例。")
                preset("检验", text: "请检查这项结论的假设、证据与适用边界，指出还需要核实的地方。")
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
            VStack(spacing: 4) {
                TextEditor(text: $model.prompt)
                    .font(.system(size: 14)).lineSpacing(3).scrollContentBackground(.hidden)
                    .frame(height: composerHeight)
                    .focused($promptFocused).disabled(model.selectedBook == nil || model.isImporting || model.isOrganizing)
                    .accessibilityLabel("阅读问题")
                    .onAppear { if !model.prompt.isEmpty || model.currentDiscussion?.messages.isEmpty == true { DispatchQueue.main.async { promptFocused = true } } }
                    .overlay(alignment: .topLeading) {
                        if model.prompt.isEmpty {
                            Text(model.selectedBook == nil ? "先打开一份 PDF" : model.isGenerating ? "可以先写下一问，稍后发送…" : "围绕原文继续提问…")
                                .font(.system(size: 14)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Menu {
                        Picker("回复方式", selection: $model.replyStyle) {
                            Text(ReplyStyle.concise.title).tag(ReplyStyle.concise)
                            Text(ReplyStyle.detailed.title).tag(ReplyStyle.detailed)
                            Text(ReplyStyle.socratic.title).tag(ReplyStyle.socratic)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.replyStyle.title)
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                        }.font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer(minLength: 2)
                    Text(model.isGenerating ? "下一问草稿" : "⌘ Return")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Button(action: model.sendMessage) { Label("发送", systemImage: "arrow.up").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent).controlSize(.small).tint(Color.accent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.selectedBook == nil || model.isBusy || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal, 4).padding(.bottom, 3)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(promptFocused ? Color.accent.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: promptFocused ? 1 : 0.5))
            .background(GeometryReader { geometry in
                Color.clear.onAppear { composerWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, value in composerWidth = value }
            })
        }.padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 11)
    }

    private var composerHeight: CGFloat {
        let text = model.prompt.isEmpty ? " " : model.prompt + " "
        let measured = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            .boundingRect(with: NSSize(width: max(100, composerWidth - 34), height: 10_000),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(availableHeight < 740 ? 100 : 160, max(40, ceil(measured) + 9))
    }

    private func preset(_ title: String, text: String) -> some View {
        Button(title) {
            model.composerPreset(text)
            promptFocused = true
        }
        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
        .disabled(model.selectedBook == nil || model.isImporting || model.isOrganizing)
        .help("填入提问草稿，不会自动发送")
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(String(format: "%02d", seconds % 60)) 秒"
    }

    private var notes: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("搜索笔记", text: $model.noteSearch).textFieldStyle(.plain).font(.system(size: 12))
                if !model.noteSearch.isEmpty {
                    Button { model.noteSearch = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 18).frame(height: 40)
            separator
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.notes.isEmpty {
                        Text(model.noteSearch.isEmpty ? "尚无笔记。可将回答存为笔记，或直接写下理解。" : "没有匹配的笔记。")
                            .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.tertiary).padding(19)
                    }
                    ForEach(model.notes) { note in
                        noteRow(note)
                        separator.padding(.horizontal, 18)
                    }
                }
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        let expanded = expandedNoteIDs.contains(note.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Button { model.openNoteEditor(existing: note) } label: {
                    Text(note.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(2)
                }.buttonStyle(.plain).disabled(model.isBusy)
                Spacer(minLength: 0)
                Menu {
                    Button("编辑笔记") { model.openNoteEditor(existing: note) }.disabled(model.isBusy)
                    Button("复制内容") { copy(note.body) }
                    Button("加入上下文篮") { model.addNoteToContext(note) }.disabled(model.isBusy)
                    Divider()
                    Button("删除笔记", role: .destructive) { model.deleteNote(note) }.disabled(model.isBusy)
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            }
            if expanded { MarkdownMessageView(text: note.body) }
            else { Text(note.body).font(.system(size: 12.5)).lineSpacing(4).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
            if !note.anchors.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote").font(.system(size: 10)).foregroundStyle(.tertiary)
                    ForEach(Array(note.anchors.prefix(4))) { anchor in
                        Button("PDF \(anchor.pageIndex + 1)") { model.jumpTo(anchor) }
                            .font(.system(size: 10.5)).buttonStyle(.plain).foregroundStyle(Color.accent).help("回到原文")
                    }
                }
            }
            HStack(spacing: 12) {
                Text(note.updatedAt, format: .dateTime.month(.twoDigits).day(.twoDigits)).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("加入上下文") { model.addNoteToContext(note) }.disabled(model.isBusy)
                Button(expanded ? "收起" : "展开") {
                    if expanded { expandedNoteIDs.remove(note.id) } else { expandedNoteIDs.insert(note.id) }
                }
                if let discussionID = note.discussionID, model.discussions.contains(where: { $0.id == discussionID }) {
                    Button("查看讨论") {
                        model.selectedDiscussionID = discussionID
                        model.rightTab = 0
                    }.disabled(model.isBusy)
                }
                Button("编辑") { model.openNoteEditor(existing: note) }.disabled(model.isBusy)
            }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionFooter: some View {
        VStack(spacing: 0) {
            separator
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 9))
                Text(model.codex.connectionStatus == "Codex 已连接" ? "本机 Codex · 已连接" : ["Codex 已断开", "尚未连接 Codex"].contains(model.codex.connectionStatus) ? "本机 Codex · 按需连接" : model.codex.connectionStatus)
                    .lineLimit(1).help(model.codex.connectionStatus)
                Spacer(minLength: 2)
                if !model.isGenerating, model.unsavedReply == nil, model.notice == "讨论已自动保存" {
                    Label("已保存", systemImage: "checkmark").lineLimit(1)
                }
            }.font(.system(size: 9.5)).foregroundStyle(.tertiary).padding(.horizontal, 15).frame(height: 28)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct InspectorImagePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, alignment: .leading) }
        }.task(id: url) { image = NSImage(contentsOf: url) }
    }
}

private struct InspectorScrollMetrics: Equatable {
    var bottom: CGFloat?
    var contentHeight: CGFloat?
    var viewportHeight: CGFloat?
}

private struct InspectorScrollPreference: PreferenceKey {
    static var defaultValue = InspectorScrollMetrics()
    static func reduce(value: inout InspectorScrollMetrics, nextValue: () -> InspectorScrollMetrics) {
        let next = nextValue()
        value.bottom = next.bottom ?? value.bottom
        value.contentHeight = next.contentHeight ?? value.contentHeight
        value.viewportHeight = next.viewportHeight ?? value.viewportHeight
    }
}
