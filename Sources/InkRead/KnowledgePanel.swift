import SwiftUI
import InkReadCore

struct KnowledgePanel: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var questionFilter: QuestionStatus?
    @State private var resumeExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("知识库内容", selection: $model.knowledgeSection) {
                    ForEach(KnowledgeSection.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(12)
            Text(sectionDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15).padding(.bottom, 12)
            HStack(spacing: 7) {
                SearchField(placeholder: "查找" + model.knowledgeSection.title, text: $search)
                Menu {
                    Button("添加疑问…") { model.openQuestionEditor() }
                    Button("收录术语或符号…") { model.openTermEditor() }
                    Button("为当前选区添加批注…") { model.openAnnotationEditor() }.disabled(model.selection == nil)
                    Divider()
                    Button("修订标签…") { model.openTagsEditor() }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("新增阅读记录")
            }.padding(.horizontal, 12).padding(.bottom, 10)
            if model.knowledgeSection == .questions {
                HStack(spacing: 8) {
                    statusFilter(nil, title: "全部")
                    ForEach(QuestionStatus.allCases, id: \.self) { statusFilter($0, title: $0.title) }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.bottom, 10)
            }
            WorkbenchHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty { resumeCard.padding(14); WorkbenchHairline() }
                    if model.knowledgeSection == .questions { questions }
                    else if model.knowledgeSection == .terms { terms }
                    else { annotations }
                }
            }
        }
        .onChange(of: model.selectedBookID) { _, _ in search = ""; questionFilter = nil }
    }

    private var sectionDescription: String {
        switch model.knowledgeSection {
        case .questions: return "留下还没弄懂的问题，之后继续讨论。"
        case .terms: return "保存本书的词义、符号和自己的理解。"
        case .annotations: return "查看你在 PDF 中留下的标记和批注。"
        }
    }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("续读卡", systemImage: "bookmark").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { resumeExpanded.toggle() } label: { Image(systemName: resumeExpanded ? "chevron.up" : "chevron.down").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if resumeExpanded {
                if let book = model.selectedBook {
                    Text("PDF \(model.pageNumber) / \(book.pageCount) · \(model.currentChapter?.title ?? "当前阅读位置")")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    if let discussion = model.currentDiscussion ?? model.discussions.first {
                        Button {
                            guard !model.isBusy else { return }
                            model.selectedDiscussionID = discussion.id; model.rightTab = 0
                        } label: {
                            Label("继续讨论：" + discussion.title, systemImage: "bubble.left").font(.system(size: 12)).lineLimit(1)
                        }.buttonStyle(.plain).foregroundStyle(Color.accent).disabled(model.isBusy)
                    }
                    if let note = model.store?.notes.filter({ $0.documentID == book.id }).max(by: { $0.updatedAt < $1.updatedAt }) {
                        Text("最近笔记：" + note.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 16) {
                        Label("\(model.unresolvedQuestions.count) 个待解决疑问", systemImage: "questionmark.circle")
                        Label("\(model.terms.count) 个术语", systemImage: "character.book.closed")
                    }.font(.system(size: 11)).foregroundStyle(.tertiary)
                    ForEach(model.unresolvedQuestions.prefix(2)) { item in
                        Button { model.discussQuestion(item) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) { Circle().fill(item.status == .verify ? Color.orange : Color.accent).frame(width: 4, height: 4); Text(item.title).lineLimit(2) }
                                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isBusy)
                    }
                } else { Text("打开一本书后显示续读信息").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }.padding(12).background(Color.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func statusFilter(_ status: QuestionStatus?, title: String) -> some View {
        Button { questionFilter = status } label: {
            Text(title).font(.system(size: 11.5, weight: questionFilter == status ? .medium : .regular))
                .foregroundStyle(questionFilter == status ? Color.accent : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 4).background(questionFilter == status ? Color.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    @ViewBuilder private var questions: some View {
        let items = model.questions.filter { (questionFilter == nil || $0.status == questionFilter) && matches($0.title + " " + $0.detail) }
        if items.isEmpty { empty("尚无匹配的疑问", detail: "把没弄明白或需要核实的问题留下来，之后继续讨论。", action: "添加疑问") { model.openQuestionEditor() } }
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.status == .resolved ? "checkmark.circle.fill" : "questionmark.circle").foregroundStyle(item.status == .resolved ? Color.accent : .secondary)
                    Text(item.title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        ForEach(QuestionStatus.allCases, id: \.self) { status in Button(status.title) { model.updateQuestionStatus(item, status: status) } }
                        Divider()
                        Button("编辑疑问…") { model.openQuestionEditor(existing: item) }
                        Button("移除疑问…", role: .destructive) { model.deleteQuestion(item) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                if !item.detail.isEmpty { Text(item.detail).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled) }
                HStack(spacing: 10) {
                    Text(item.status.title).font(.system(size: 11)).foregroundStyle(item.status == .verify ? Color.orange : .secondary)
                    if let anchor = item.anchor { Button("PDF \(anchor.pageIndex + 1)") { model.jumpTo(anchor) }.foregroundStyle(Color.accent) }
                    Spacer()
                    Button("继续讨论") { model.discussQuestion(item) }.disabled(model.isBusy)
                }.font(.system(size: 11.5)).buttonStyle(.plain)
            }.padding(16)
            WorkbenchHairline().padding(.horizontal, 16)
        }
    }
    @ViewBuilder private var terms: some View {
        let items = model.terms.filter { matches($0.term + " " + $0.meaning + " " + $0.scope) }
        if items.isEmpty { empty("尚无匹配的术语", detail: "选中术语或符号，保存本书里的定义、章节和自己的理解。", action: "收录术语") { model.openTermEditor() } }
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.term).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    Spacer()
                    Menu {
                        Button("编辑词条…") { model.openTermEditor(existing: item) }
                        Button("加入上下文篮") { model.addTermToContext(item) }
                        Button("移除词条…", role: .destructive) { model.deleteTerm(item) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                if !item.scope.isEmpty { Text(item.scope).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(2) }
                if item.meaning.isEmpty { Text("尚未填写释义").font(.system(size: 13)).foregroundStyle(.tertiary) }
                else { MarkdownMessageView(text: item.meaning) }
                HStack {
                    ForEach(item.anchors.prefix(3)) { anchor in Button("PDF \(anchor.pageIndex + 1)") { model.jumpTo(anchor) }.foregroundStyle(Color.accent) }
                    Spacer()
                    Button("加入上下文") { model.addTermToContext(item) }
                    Button("编辑") { model.openTermEditor(existing: item) }
                }.font(.system(size: 11.5)).buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(16)
            WorkbenchHairline().padding(.horizontal, 16)
        }
    }
    @ViewBuilder private var annotations: some View {
        let items = model.annotations.filter { matches(($0.anchor.selectedText ?? "") + " " + $0.body + " " + $0.color.title) }
        HStack {
            Text("\(items.count) 条批注").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            WorkbenchIcon("撤销批注操作", symbol: "arrow.uturn.backward", enabled: model.canUndoAnnotation) { model.undoAnnotation() }
            WorkbenchIcon("重做批注操作", symbol: "arrow.uturn.forward", enabled: model.canRedoAnnotation) { model.redoAnnotation() }
        }.padding(.horizontal, 14).padding(.top, 10)
        if items.isEmpty { empty("尚无匹配的批注", detail: "选中文字后高亮或加下划线，框选区域后加彩色方框。", action: nil, perform: {}) }
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(Color(annotationColor: item.color)).frame(width: 8, height: 8)
                    Button("\(item.style.title) · PDF \(item.anchor.pageIndex + 1)") { model.jumpTo(item.anchor) }.foregroundStyle(Color.accent)
                    Spacer()
                    Menu {
                        Button("编辑批注…") { model.openAnnotationEditor(existing: item) }
                        Button("加入上下文篮") { model.addAnchorToContext(item.anchor) }
                        Button("固定参考页") { model.pinAnchor(item.anchor) }
                        Divider()
                        Button("删除批注", role: .destructive) { model.deleteAnnotation(item) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 12)).buttonStyle(.plain)
                if let quote = item.anchor.selectedText, !quote.isEmpty { Text(quote).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled) }
                if !item.body.isEmpty { Text(item.body).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled) }
                HStack { Text(item.updatedAt, format: .dateTime.month().day()).foregroundStyle(.tertiary); Spacer(); Button("编辑") { model.openAnnotationEditor(existing: item) } }.font(.system(size: 11.5)).buttonStyle(.plain)
            }.padding(16)
            WorkbenchHairline().padding(.horizontal, 16)
        }
    }
    private func empty(_ title: String, detail: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(4)
            if let action { Button(action, action: perform).buttonStyle(.link).font(.system(size: 12.5)).disabled(model.selectedBook == nil) }
        }.padding(18)
    }
}

struct ReadingFeatureEditor: View {
    @ObservedObject var model: AppModel
    let kind: FeatureSheet
    private var title: String { switch kind { case .annotation: return "彩色批注"; case .question: return "阅读疑问"; case .term: return "术语与符号"; case .tags: return "修订本书标签" } }
    private var canSave: Bool {
        guard !model.isOrganizing else { return false }
        switch kind { case .annotation, .tags: return true; case .question: return !model.questionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty; case .term: return !model.termName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.system(size: 15, weight: .semibold)); Spacer(); if let anchor = model.featureAnchor { Text("PDF \(anchor.pageIndex + 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) } }.padding(22)
            WorkbenchHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if kind == .annotation { annotation }
                    else if kind == .question { question }
                    else if kind == .term { term }
                    else { tags }
                    if let quote = model.featureAnchor?.selectedText, !quote.isEmpty, kind != .tags {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("原文引用").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tertiary)
                            Text(quote).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(22)
            }
            if !model.featureStatus.isEmpty && (kind == .term || kind == .tags) {
                HStack(spacing: 8) { if model.isOrganizing { ProgressView().controlSize(.mini) }; Text(model.featureStatus).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3); Spacer(); if model.isOrganizing { Button("停止") { model.cancelResponse() }.font(.system(size: 12)) } }.padding(.horizontal, 22).padding(.bottom, 14)
            }
            WorkbenchHairline()
            HStack {
                Text(kind == .tags ? "保存后才会更新书籍标签" : "与本书一起保存在本机").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: model.closeFeatureEditor).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(.horizontal, 22).frame(height: 58).background(Color.workbenchChrome)
        }.frame(width: 620, height: kind == .tags ? 460 : 560).background(Color.paper)
    }
    private var annotation: some View {
        VStack(alignment: .leading, spacing: 17) {
            Picker("样式", selection: $model.annotationStyle) { ForEach(ReadingAnnotation.Style.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            HStack(spacing: 13) {
                Text("颜色").font(.system(size: 13)).foregroundStyle(.secondary)
                ForEach(AnnotationColor.allCases, id: \.self) { color in
                    Button { model.annotationColor = color } label: {
                        Circle().fill(Color(annotationColor: color)).frame(width: 23, height: 23)
                            .overlay { if model.annotationColor == color { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black.opacity(0.7)) } }
                    }.buttonStyle(.plain).help(color.title).accessibilityLabel(color.title + (model.annotationColor == color ? "，已选择" : ""))
                }
            }
            Text("批注内容（可留空）").font(.system(size: 13)).foregroundStyle(.secondary)
            TextEditor(text: $model.annotationBody).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).frame(height: 160).background(Color.workbenchChrome, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    private var question: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("我还没弄明白的问题", text: $model.questionTitle).font(.system(size: 16, weight: .medium)).textFieldStyle(.plain)
            Picker("状态", selection: $model.questionStatus) { ForEach(QuestionStatus.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text("疑问、已有判断或下一步要核实的内容").font(.system(size: 12.5)).foregroundStyle(.secondary)
            TextEditor(text: $model.questionDetail).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).frame(height: 190).background(Color.workbenchChrome, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    private var term: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("术语或符号，如 FPGA、λ", text: $model.termName).font(.system(size: 18, weight: .semibold)).textFieldStyle(.plain).disabled(model.isOrganizing)
            TextField("适用章节或范围", text: $model.termScope).textFieldStyle(.roundedBorder).disabled(model.isOrganizing)
            HStack {
                Text("释义与自己的理解").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Button { model.suggestTermMeaning() } label: { Label("请 Codex 拟释义", systemImage: "sparkles") }.font(.system(size: 12)).disabled(model.isBusy || model.termName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextEditor(text: $model.termMeaning).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).frame(height: 210).background(Color.workbenchChrome, in: RoundedRectangle(cornerRadius: 6)).disabled(model.isOrganizing)
        }
    }
    private var tags: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用逗号或换行分隔标签，随时可以增删、修订。").font(.system(size: 13)).foregroundStyle(.secondary)
            TextEditor(text: $model.tagsText).font(.system(size: 15)).scrollContentBackground(.hidden).padding(8).frame(height: 95).background(Color.workbenchChrome, in: RoundedRectangle(cornerRadius: 6)).disabled(model.isOrganizing)
            HStack { Text("\(model.editedTags.count) 个标签").font(.system(size: 12)).foregroundStyle(.tertiary); Spacer(); Button { model.suggestTags() } label: { Label("按本书内容建议标签", systemImage: "sparkles") }.font(.system(size: 12.5)).disabled(model.isBusy) }
            if !model.suggestedTags.isEmpty {
                Text("点选要保留的建议").font(.system(size: 12)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.suggestedTags, id: \.self) { tag in
                        let selected = model.editedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                        Button { model.toggleSuggestedTag(tag) } label: {
                            HStack(spacing: 5) { Image(systemName: selected ? "checkmark" : "plus").font(.system(size: 10)); Text(tag).font(.system(size: 12)).lineLimit(2) }.padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? Color.accent.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(selected ? Color.accent : .secondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private func save() { switch kind { case .annotation: model.saveAnnotation(); case .question: model.saveQuestion(); case .term: model.saveTerm(); case .tags: model.saveTags() } }
}

extension Color {
    init(annotationColor: AnnotationColor) {
        let hex = UInt64(annotationColor.hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct ResumePopover: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("续读卡", systemImage: "bookmark").font(.system(size: 15, weight: .semibold))
            Text(model.selectedBook?.title ?? "").font(.system(size: 13, weight: .medium)).lineLimit(2)
            Text("PDF \(model.pageNumber) · \(model.currentChapter?.title ?? "阅读位置")").font(.system(size: 12)).foregroundStyle(.secondary)
            if let discussion = model.currentDiscussion ?? model.discussions.first {
                Button("继续讨论：" + discussion.title) { guard !model.isBusy else { return }; model.selectedDiscussionID = discussion.id; model.showInspector = true; model.rightTab = 0 }.font(.system(size: 13)).buttonStyle(.link).disabled(model.isBusy)
            }
            Divider()
            Text(model.unresolvedQuestions.isEmpty ? "没有待解决的疑问" : "待解决疑问").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(model.unresolvedQuestions.prefix(4)) { item in Button { model.discussQuestion(item) } label: { Label(item.title, systemImage: item.status == .verify ? "checkmark.magnifyingglass" : "questionmark.circle").font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading) }.buttonStyle(.plain).disabled(model.isBusy) }
            if let note = model.store?.notes.filter({ $0.documentID == model.selectedBookID }).max(by: { $0.updatedAt < $1.updatedAt }) {
                Text("最近笔记：" + note.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("打开疑问队列") { model.openKnowledge(.questions) }.font(.system(size: 12)).buttonStyle(.link)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReferenceHeightDivider: View {
    @Binding var height: CGFloat
    let limit: ClosedRange<CGFloat>
    @State private var start: CGFloat?
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(height: 5).overlay { Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 28, height: 2) }
            .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if start == nil { start = height }
                height = min(limit.upperBound, max(limit.lowerBound, (start ?? height) - value.translation.height))
            }.onEnded { _ in start = nil }).help("拖动调整参考页高度")
    }
}
