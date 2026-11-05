import SwiftUI
import AppKit
import InkReadCore

/// The reading workspace's compact discussion and notes column. All mutations go
/// through AppModel; choosing another passage never changes a thread implicitly.
struct ResearchInspector: View {
    @ObservedObject var model: AppModel
    @State private var showingHistory = false
    @State private var historyQuery = ""
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
                discussionToolbar
                separator
                conversation.frame(minHeight: availableHeight < 740 ? 100 : 140)
                composer
            } else if model.rightTab == 1 {
                notes
            } else {
                KnowledgePanel(model: model)
            }
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
            tab("讨论", count: nil, value: 0)
            tab("笔记", count: totalNotes, value: 1)
            tab("知识库", count: nil, value: 2)
            Spacer(minLength: 0)
            if model.rightTab == 1 {
                Button { model.openNoteEditor() } label: {
                    Label("写笔记", systemImage: "square.and.pencil").font(.system(size: 12.5, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.selectedBook == nil || model.isBusy)
            }
        }
        .padding(.horizontal, 18).frame(height: 47)
    }

    private func tab(_ title: String, count: Int?, value: Int) -> some View {
        Button { model.rightTab = value } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 14, weight: model.rightTab == value ? .semibold : .regular))
                    if let count { Text(String(count)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary) }
                }.frame(maxHeight: .infinity)
                Rectangle().fill(model.rightTab == value ? Color.accent : .clear).frame(height: 2)
            }
            .foregroundStyle(model.rightTab == value ? Color.primary : .secondary)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(count.map { "\(title)，\($0) 项" } ?? title)
    }

    private var discussionToolbar: some View {
        HStack(spacing: 12) {
            Text(model.currentDiscussion?.title ?? "新讨论")
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                .help(model.currentDiscussion?.title ?? "围绕本书或选中的原文提问")
                .contextMenu { discussionActions }
            Spacer(minLength: 0)
            Button { showingHistory.toggle() } label: {
                Label("历史", systemImage: "clock.arrow.circlepath").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("查找和继续之前的讨论")
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) { historyPopover }
            Button {
                model.startDiscussion(useSelection: false)
                promptFocused = true
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(model.selectedBook == nil || model.isBusy)
                .help("新建讨论").accessibilityLabel("新建讨论")
        }.padding(.horizontal, 18).frame(height: 43)
    }

    @ViewBuilder private var discussionActions: some View {
        if let discussion = model.currentDiscussion {
            Button("重命名讨论") { model.renameDiscussion() }.disabled(model.isBusy)
            Button("整段讨论加入引用材料") { model.addDiscussionToContext(discussion) }.disabled(model.isBusy)
            Button("记为疑问") { model.createQuestionFromDiscussion(discussion) }.disabled(model.isBusy)
            questionStatusMenu(discussion)
        }
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("历史讨论").font(.system(size: 14, weight: .semibold))
                Text("\(model.discussions.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if model.currentDiscussion != nil {
                    Menu { discussionActions } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().help("当前讨论的更多操作")
                }
            }
            SearchField(placeholder: "查找标题、原文或讨论内容", text: $historyQuery)
            if historyResults.isEmpty {
                Text(model.discussions.isEmpty ? "尚无讨论。先在下方输入一个问题。" : "没有匹配的讨论。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(historyResults) { discussion in historyRow(discussion) }
                    }
                }.frame(height: min(330, CGFloat(historyResults.count) * 49))
            }
        }.padding(16).frame(width: 350)
    }

    private func historyRow(_ discussion: Discussion) -> some View {
        let selected = discussion.id == model.selectedDiscussionID
        let answers = discussion.messages.filter { $0.role == .assistant && $0.status == .completed }.count
        return Button {
            model.selectedDiscussionID = discussion.id
            showingHistory = false
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1).fill(selected ? Color.accent : .clear).frame(width: 2, height: 25)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(discussion.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                            .foregroundStyle(.primary).lineLimit(1)
                        if let status = model.questions.first(where: { $0.discussionID == discussion.id })?.status {
                            Image(systemName: questionIcon(status)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .help(questionTitle(status))
                        }
                    }
                    HStack(spacing: 7) {
                        Text(discussion.anchor.map { "PDF \($0.pageIndex + 1)" } ?? "本书")
                        Text("·")
                        Text("\(answers) 条回答")
                        Spacer(minLength: 4)
                        Text(discussion.updatedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                    }.font(.system(size: 11)).foregroundStyle(.tertiary)
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
                Button("加入引用材料") { model.addDiscussionToContext(discussion) }.disabled(model.isBusy)
                Button("记为疑问") { model.createQuestionFromDiscussion(discussion) }.disabled(model.isBusy)
                questionStatusMenu(discussion)
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
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.selectedBook == nil ? "从一份 PDF 开始" : "把疑问留在原文旁")
                                .font(.system(size: 17, weight: .medium))
                            Text(model.selectedBook == nil ? "导入书籍或论文后，就可以边读边问。" : "选中原文 → 输入问题 → 保存有用的回答")
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                            if model.selectedBook != nil {
                                Text("也可以直接询问本书，无需先选中内容。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                            }
                        }.padding(.top, 14)
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
                        Label("回到最新", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
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
                    Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Color.accent)
                }
                Text(message.role == .user ? "我" : "Codex")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(message.createdAt, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if message.status == .failed || message.status == .interrupted {
                    Text(message.status == .failed ? "未完成" : "已停止").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if body.isEmpty && message.status == .inProgress {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("正在准备回答…").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            } else if message.role == .user {
                Text(body).font(.system(size: 14.5)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownMessageView(text: body)
            }
            if message.role == .user {
                SentContextSnapshot(items: message.contextItems, model: model)
            }
            if !body.isEmpty {
                HStack(spacing: 16) {
                    if message.role == .assistant && message.status == .completed {
                        Button { model.openNoteEditor(answer: message) } label: {
                            Label("保存笔记", systemImage: "bookmark")
                        }.disabled(model.isBusy).foregroundStyle(Color.accent)
                            .help("将这条回答和原文引用一起保存")
                    }
                    Button { copy(body) } label: { Label("复制", systemImage: "doc.on.doc") }
                    Menu {
                        Button("加入引用材料") { model.addMessageToContext(message) }
                            .disabled(model.isBusy)
                        Button("从这里另开讨论") { model.forkDiscussion(through: message) }
                            .disabled(model.isBusy || message.status == .inProgress)
                    } label: { Image(systemName: "ellipsis").frame(width: 20) }
                        .menuStyle(.borderlessButton).fixedSize().help("更多消息操作")
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !body.isEmpty { Button("复制内容") { copy(body) } }
            if message.role == .assistant && message.status == .completed && !body.isEmpty {
                Button("存为笔记") { model.openNoteEditor(answer: message) }.disabled(model.isBusy)
            }
            if !body.isEmpty {
                Button("加入引用材料") { model.addMessageToContext(message) }.disabled(model.isBusy)
                Button("从这里另开讨论") { model.forkDiscussion(through: message) }
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
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            Text(error).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary)
                .lineLimit(4).textSelection(.enabled)
            HStack {
                Text(retryAvailable ? "原问题和已有回复已保留。" : "草稿仍保留，可调整后再次发送。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if retryAvailable {
                    Button("在新分支重试", action: model.retryLastQuestion)
                        .font(.system(size: 11.5, weight: .medium)).buttonStyle(.plain).foregroundStyle(Color.accent)
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
            }.font(.system(size: 12)).buttonStyle(.plain)
            Text(model.unsavedReplyOrigin).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
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
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).help(model.activity)
                    Spacer(minLength: 0)
                    if let startedAt = model.responseStartedAt {
                        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                            Text(elapsed(since: startedAt, now: timeline.date))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    Button("停止", action: model.cancelResponse)
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }.padding(.horizontal, 3).padding(.vertical, 3)
            }
            ContextBasketView(model: model, compact: availableHeight < 740)
            VStack(spacing: 8) {
                TextEditor(text: $model.prompt)
                    .font(.system(size: 15)).lineSpacing(3).scrollContentBackground(.hidden)
                    .frame(height: composerHeight)
                    .focused($promptFocused).disabled(model.selectedBook == nil || model.isImporting || model.isOrganizing)
                    .accessibilityLabel("阅读问题")
                    .onAppear { if !model.prompt.isEmpty || model.currentDiscussion?.messages.isEmpty == true { DispatchQueue.main.async { promptFocused = true } } }
                    .overlay(alignment: .topLeading) {
                        if model.prompt.isEmpty {
                            Text(model.selectedBook == nil ? "先打开一份 PDF" : model.isGenerating ? "先写下一问，稍后发送…" : "输入关于原文的问题…")
                                .font(.system(size: 15)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 12) {
                    Menu {
                        preset("解释这段内容", text: "请解释当前材料的核心含义，指出关键前提，并引用原文页码。")
                        preset("补全公式推导", text: "请逐步补全相关公式的推导，说明每一步使用的假设、符号和适用条件。")
                        preset("举个具体例子", text: "请用一个具体的小例子说明当前材料，再给出一个容易误用的反例。")
                        preset("检查前提与证据", text: "请检查这项结论的假设、证据与适用边界，指出还需要核实的地方。")
                    } label: {
                        Text("提问建议").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        Text("回答方式")
                        replyStyleOption("简短", explanation: "先说结论，保留重点", style: .concise)
                        replyStyleOption("详细解释", explanation: "展开推导和例子", style: .detailed)
                        replyStyleOption("引导思考", explanation: "用问题检验理解", style: .socratic)
                    } label: {
                        Text("选项").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.menuStyle(.borderlessButton).fixedSize().help("选择 Codex 的回答方式")
                    Spacer(minLength: 0)
                    Text("⌘↵").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    Button(action: model.sendMessage) { Label("发送", systemImage: "arrow.up").font(.system(size: 12, weight: .medium)) }
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
            CodexGenerationControls(model: model).padding(.horizontal, 3)
        }.padding(.horizontal, 13).padding(.top, 9).padding(.bottom, 12)
    }

    private var composerHeight: CGFloat {
        let text = model.prompt.isEmpty ? " " : model.prompt + " "
        let measured = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
            .boundingRect(with: NSSize(width: max(100, composerWidth - 34), height: 10_000),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(availableHeight < 740 ? 100 : 160, max(40, ceil(measured) + 9))
    }

    private func preset(_ title: String, text: String) -> some View {
        Button(title) {
            model.composerPreset(text)
            promptFocused = true
        }
        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
        .disabled(model.selectedBook == nil || model.isImporting || model.isOrganizing)
        .help("填入提问草稿，不会自动发送")
    }

    private func replyStyleOption(_ title: String, explanation: String, style: ReplyStyle) -> some View {
        Button { model.replyStyle = style } label: {
            if model.replyStyle == style { Label(title + " · " + explanation, systemImage: "checkmark") }
            else { Text(title + " · " + explanation) }
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(String(format: "%02d", seconds % 60)) 秒"
    }

    private var notes: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                TextField("搜索笔记", text: $model.noteSearch).textFieldStyle(.plain).font(.system(size: 13))
                if !model.noteSearch.isEmpty {
                    Button { model.noteSearch = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 18).frame(height: 40)
            separator
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.notes.isEmpty {
                        Text(model.noteSearch.isEmpty ? "尚无笔记。可将回答存为笔记，或直接写下理解。" : "没有匹配的笔记。")
                            .font(.system(size: 13)).lineSpacing(4).foregroundStyle(.tertiary).padding(19)
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
                    Text(note.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(2)
                }.buttonStyle(.plain).disabled(model.isBusy)
                Spacer(minLength: 0)
                Menu {
                    Button("编辑笔记") { model.openNoteEditor(existing: note) }.disabled(model.isBusy)
                    Button("复制内容") { copy(note.body) }
                    Button("加入引用材料") { model.addNoteToContext(note) }.disabled(model.isBusy)
                    Divider()
                    Button("删除笔记", role: .destructive) { model.deleteNote(note) }.disabled(model.isBusy)
                } label: { Image(systemName: "ellipsis").font(.system(size: 13)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            }
            if expanded { MarkdownMessageView(text: note.body) }
            else { Text(note.body).font(.system(size: 13.5)).lineSpacing(4).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
            if !note.anchors.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote").font(.system(size: 11)).foregroundStyle(.tertiary)
                    ForEach(Array(note.anchors.prefix(4))) { anchor in
                        Button("PDF \(anchor.pageIndex + 1)") { model.jumpTo(anchor) }
                            .font(.system(size: 11.5)).buttonStyle(.plain).foregroundStyle(Color.accent).help("回到原文")
                    }
                }
            }
            HStack(spacing: 12) {
                Text(note.updatedAt, format: .dateTime.month(.twoDigits).day(.twoDigits)).font(.system(size: 11)).foregroundStyle(.tertiary)
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
            }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
