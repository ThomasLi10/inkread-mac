import SwiftUI
import AppKit
import InkReadCore

/// One compact preview of the actual next-send materials. Advanced attachment
/// management is disclosed on demand; opening it never mutates the context.
struct ContextBasketView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var presented = false

    private var nextMaterials: [ContextItem] {
        if let discussion = model.currentDiscussion { return model.effectiveContext(for: discussion) }
        guard let book = model.selectedBook else { return model.contextItems }
        // A new discussion will capture this selection when the question is
        // sent. Preview its geometry without writing an image or starting a chat.
        let anchor = model.selection.map { selection in
            SourceAnchor(documentID: book.id, pageIndex: selection.pageIndex, pageLabel: selection.pageLabel,
                         rects: selection.rects, selectedText: selection.text.isEmpty ? nil : selection.text)
        }
        return model.effectiveContext(for: Discussion(documentID: book.id, anchor: anchor))
    }

    private var selectionIncluded: Bool {
        guard let selection = model.selection else { return false }
        return nextMaterials.contains { item in item.anchors.contains {
            $0.documentID == model.selectedBookID && $0.pageIndex == selection.pageIndex && $0.rects == selection.rects
        } }
    }

    private var canAttachSelection: Bool { model.selection != nil && !selectionIncluded }

    private var summary: String {
        if nextMaterials.isEmpty { return "引用原文（可选）" }
        if nextMaterials.count == 1, let item = nextMaterials.first,
           item.noteID == nil, item.discussionID == nil, let anchor = item.anchors.first {
            return "引用原文 · PDF \(anchor.pageIndex + 1)"
        }
        return "引用 \(nextMaterials.count) 项材料"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { presented.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 11))
                    Text(summary).font(.system(size: 12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(model.selectedBook == nil)
                .help("查看下一问会带入的原文、笔记与附加材料")
                .accessibilityLabel("本次引用：" + summary)
                .popover(isPresented: $presented, arrowEdge: .top) { materialDetails }
            Spacer(minLength: 0)
            if canAttachSelection {
                Button("附上选区", action: model.addSelectionToContext)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accent)
                    .disabled(model.isBusy).help("把刚选中的内容附到下一次提问")
            }
        }.frame(minHeight: 25).padding(.horizontal, 3)
            .onChange(of: model.selectedBookID) { _, _ in presented = false }
    }

    private var materialDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本次引用").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(nextMaterials.count) 项").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("下面的材料会随下一问发送。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if canAttachSelection, let selection = model.selection {
                VStack(alignment: .leading, spacing: 8) {
                    Text("刚选中的内容 · PDF \(selection.pageIndex + 1)")
                        .font(.system(size: 12, weight: .medium))
                    Text(selection.imageData == nil ? String(selection.text.prefix(240)) : "一处图表选区")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    HStack {
                        Button("附到这次提问", action: model.addSelectionToContext).foregroundStyle(Color.accent)
                            .disabled(model.isBusy)
                        Spacer()
                        Button("清除选区", action: model.clearReaderSelection).foregroundStyle(.secondary)
                    }.font(.system(size: 12)).buttonStyle(.plain)
                }.padding(11).background(Color.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            if nextMaterials.isEmpty {
                Text("可以直接询问本书，也可以先在 PDF 中选中文字或图表。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(nextMaterials) { item in
                            if model.contextItems.contains(where: { $0.id == item.id }) {
                                ContextMaterialRow(item: item, model: model, remove: { model.removeContextItem(id: item.id) })
                            } else {
                                ContextMaterialRow(item: item, model: model, remove: nil)
                            }
                        }
                    }
                }.frame(height: min(compact ? 230 : 300, CGFloat(nextMaterials.count) * 58))
            }
            if model.currentDiscussion?.anchor != nil {
                Text("这条讨论会保留最初的原文引用；新讨论可更换引用。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(2)
            }
            WorkbenchHairline()
            HStack {
                Menu("添加材料") {
                    Button("附上当前选区", action: model.addSelectionToContext)
                        .disabled(model.selection == nil || selectionIncluded)
                    if model.selection != nil {
                        Button("为选区新建讨论") {
                            let draft = model.prompt
                            model.startDiscussion()
                            model.prompt = draft
                            presented = false
                        }
                        Button("固定选区为参考位置", action: model.pinSelection)
                    }
                    if let discussion = model.currentDiscussion {
                        Button("附上整段讨论") { model.addDiscussionToContext(discussion) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
                Spacer(minLength: 0)
                if !model.contextItems.isEmpty {
                    Button("清除附加材料", action: model.clearContextBasket)
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isBusy)
                }
            }.font(.system(size: 12))
        }.padding(17).frame(width: 350)
    }
}

/// A historical attachment list, rendered only from the saved user-message
/// snapshot. `nil` means the old library never recorded this information.
struct SentContextSnapshot: View {
    let items: [ContextItem]?
    @ObservedObject var model: AppModel
    @State private var presented = false

    var body: some View {
        if let items {
            Button { presented.toggle() } label: {
                Label("引用 \(items.count) 项", systemImage: "paperclip")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $presented, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text("这次发送的引用").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(items.count) 项").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text("以下是这条问题发送时使用的材料，之后的修改不会影响它。")
                        .font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(.secondary)
                    if items.isEmpty {
                        Text("这次没有附加材料，仍会延续本讨论已有的对话。")
                            .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(items) { item in ContextMaterialRow(item: item, model: model, remove: nil) }
                            }
                        }.frame(maxHeight: 370)
                    }
                }.padding(16).frame(width: 335)
            }
            .help("查看这条消息实际发送时保存的材料")
        } else {
            Text("旧消息未记录引用明细").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}

private struct ContextMaterialRow: View {
    let item: ContextItem
    @ObservedObject var model: AppModel
    let remove: (() -> Void)?
    @State private var presented = false

    private var icon: String {
        if item.noteID != nil { return "note.text" }
        if item.anchors.contains(where: { $0.imageRelativePath != nil }) { return "photo" }
        if item.discussionID != nil { return "bubble.left.and.bubble.right" }
        return "text.quote"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 13).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Button { presented.toggle() } label: {
                    Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("查看这项材料")
                    .popover(isPresented: $presented, arrowEdge: .leading) {
                        ContextMaterialPreview(item: item, model: model)
                    }
                HStack(spacing: 7) {
                    Text(item.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    ContextSourceJump(anchors: item.anchors, model: model)
                        .font(.system(size: 10.5))
                }
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8.5)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).disabled(model.isBusy)
                    .padding(.top, 3).help("从待发送材料中移除")
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.3)).frame(height: 0.5) }
    }
}

private struct ContextMaterialPreview: View {
    let item: ContextItem
    @ObservedObject var model: AppModel
    @State private var images: [ContextPreviewImage] = []

    private var sourceImages: [(path: String, pageIndex: Int)] {
        var seen = Set<String>()
        return item.anchors.compactMap { anchor in
            guard let path = anchor.imageRelativePath, seen.insert(path).inserted else { return nil }
            return (path, anchor.pageIndex)
        }
    }

    private var copyTitle: String {
        if !item.body.isEmpty { return sourceImages.isEmpty ? "复制材料" : "复制文字" }
        return sourceImages.count > 1 ? "复制 \(sourceImages.count) 张图表" : "复制图像"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
            if !item.anchors.isEmpty {
                HStack {
                    Text("\(item.anchors.count) 处来源" + (sourceImages.isEmpty ? "" : " · \(sourceImages.count) 张图表"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    ContextSourceJump(anchors: item.anchors, model: model).font(.system(size: 11.5))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("图表 \(index + 1) · PDF \(image.pageIndex + 1)")
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            Image(nsImage: image.image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 115, alignment: .leading)
                        }
                    }
                    if sourceImages.count > 3 {
                        Text("另有 \(sourceImages.count - 3) 张关联图表，可从来源菜单跳回原文。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if min(3, sourceImages.count) > images.count {
                        Text("\(min(3, sourceImages.count) - images.count) 张图表预览暂不可用，仍可跳回来源。")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    MarkdownMessageView(text: item.body)
                }
            }.frame(maxHeight: 350)
            HStack {
                Spacer()
                Button {
                    if item.body.isEmpty {
                        let allImages = sourceImages.compactMap { source -> NSImage? in
                            guard let url = model.store?.assetURL(relativePath: source.path) else { return nil }
                            return NSImage(contentsOf: url)
                        }
                        guard !allImages.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects(allImages)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.body, forType: .string)
                    }
                } label: { Label(copyTitle, systemImage: "doc.on.doc").font(.system(size: 11.5)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(item.body.isEmpty && sourceImages.isEmpty)
            }
        }.padding(16).frame(width: 340)
            .task(id: item.anchors) {
                images = sourceImages.prefix(3).compactMap { source in
                    guard let url = model.store?.assetURL(relativePath: source.path), let image = NSImage(contentsOf: url) else { return nil }
                    return ContextPreviewImage(path: source.path, pageIndex: source.pageIndex, image: image)
                }
            }
    }
}

private struct ContextPreviewImage: Identifiable {
    let path: String
    let pageIndex: Int
    let image: NSImage
    var id: String { path }
}

/// The count refers to source locations, not just distinct page numbers: two
/// separate figures on the same page remain individually navigable.
private struct ContextSourceJump: View {
    let anchors: [SourceAnchor]
    @ObservedObject var model: AppModel

    var body: some View {
        if let first = anchors.first {
            if anchors.count == 1 {
                Button("PDF \(first.pageIndex + 1)") { model.jumpTo(first) }
                    .buttonStyle(.plain).foregroundStyle(Color.accent).help("回到材料来源")
            } else {
                Menu {
                    ForEach(Array(anchors.enumerated()), id: \.element.id) { index, anchor in
                        Button { model.jumpTo(anchor) } label: {
                            Label("PDF \(anchor.pageIndex + 1) · 来源 \(index + 1)",
                                  systemImage: anchor.imageRelativePath == nil ? "text.quote" : "photo")
                        }
                    }
                } label: { Text("PDF \(first.pageIndex + 1) +\(anchors.count - 1)") }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Color.accent)
                    .help("查看全部 \(anchors.count) 处来源")
            }
        }
    }
}
