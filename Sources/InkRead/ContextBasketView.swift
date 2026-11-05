import SwiftUI
import AppKit
import InkReadCore

/// Editable material for a future send. SentContextSnapshot below deliberately
/// reads ChatMessage.contextItems instead of this live, persistent basket.
struct ContextBasketView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var expanded = false

    private var basketImageCount: Int {
        Set(model.contextItems.flatMap(\.anchors).compactMap(\.imageRelativePath)).count
    }

    private var nextSendCount: Int {
        if let discussion = model.currentDiscussion { return model.effectiveContext(for: discussion).count }
        guard let book = model.selectedBook else { return model.contextItems.count }
        // Preview the new thread's prospective anchor without saving an image or
        // creating a discussion. Actual historical snapshots still come only
        // from ChatMessage.contextItems after the model submits the question.
        let anchor = model.selection.map { selection in
            SourceAnchor(documentID: book.id, pageIndex: selection.pageIndex, pageLabel: selection.pageLabel,
                         rects: selection.rects, selectedText: selection.text.isEmpty ? nil : selection.text)
        }
        return model.effectiveContext(for: Discussion(documentID: book.id, anchor: anchor)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        Image(systemName: "tray").font(.system(size: 11.5))
                        Text("上下文篮").font(.system(size: 12, weight: .medium))
                        Text(String(model.contextItems.count)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        if basketImageCount > 0 {
                            Label(String(basketImageCount), systemImage: "photo")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .help("篮中材料关联 \(basketImageCount) 张图表")
                        }
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
                Text("下次发送 \(nextSendCount) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                if !model.contextItems.isEmpty {
                    Button("清空") { model.clearContextBasket() }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(model.isBusy).help("清空待发送材料，不影响已经发送的消息")
                }
                Menu {
                    Button("加入当前选区", action: model.addSelectionToContext).disabled(model.selection == nil)
                    if let discussion = model.currentDiscussion {
                        Button("加入当前讨论") { model.addDiscussionToContext(discussion) }
                    }
                } label: { Image(systemName: "plus").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                    .disabled(model.isBusy || model.selectedBook == nil).help("添加待讨论的材料")
            }
            if expanded {
                if model.contextItems.isEmpty {
                    Text(nextSendCount > 0 ? "篮中暂无附加材料；讨论引用会随下一问发送。" : "把选区、笔记或回答加入这里；添加材料不会自动发送。")
                        .font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.contextItems) { item in
                                ContextMaterialRow(item: item, model: model, remove: { model.removeContextItem(id: item.id) })
                            }
                        }
                    }.frame(height: min(compact ? 68 : 126, CGFloat(model.contextItems.count) * 54))
                    Text("材料会留在篮中，方便下一问继续使用。")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 3).padding(.vertical, 3)
        .onChange(of: model.contextItems.count) { previous, current in
            if previous == 0, current > 0 { expanded = true }
        }
        .onChange(of: model.selectedBookID) { _, _ in expanded = false }
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
                Label("本次材料 \(items.count)", systemImage: "paperclip")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $presented, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text("此次发送的材料").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(items.count) 项").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text("以下是发送时保存的快照，与现在的上下文篮独立。")
                        .font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(.secondary)
                    if items.isEmpty {
                        Text("这次发送没有附加篮中材料。原讨论引用及已有对话仍由对应讨论保留。")
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
            Text("旧消息 · 未记录材料快照").font(.system(size: 10.5)).foregroundStyle(.tertiary)
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
