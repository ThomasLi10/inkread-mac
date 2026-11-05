import SwiftUI
import AppKit

/// A lookup stays beside the page; saving it is an explicit action that keeps
/// the captured source, rather than whichever passage is selected afterwards.
struct TranslationPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("EN → 中文").font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(0.6).foregroundStyle(.secondary)
                    Text(model.translationTerm).font(.system(size: 21, weight: .medium))
                        .lineLimit(3).textSelection(.enabled)
                    HStack(spacing: 9) {
                        Text("Codex · 语境翻译").foregroundStyle(.secondary)
                        if let anchor = model.translationAnchor {
                            Button("PDF \(anchor.pageIndex + 1)") { model.jumpTo(anchor) }
                                .buttonStyle(.plain).foregroundStyle(Color.accent)
                                .help("回到这次翻译的原文位置")
                        }
                    }.font(.system(size: 11.5))
                }
                Spacer(minLength: 0)
                Button(action: model.closeTranslation) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("关闭翻译").accessibilityLabel("关闭翻译")
            }.padding(18)
            WorkbenchHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.translationText.isEmpty {
                        MarkdownMessageView(text: model.translationText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.isTranslating {
                        HStack(alignment: .top, spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(model.translationActivity.isEmpty ? "正在结合原文翻译…" : model.translationActivity)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }.padding(.vertical, 3)
                    }
                    if let error = model.translationError {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(.orange)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            WorkbenchHairline()
            HStack(spacing: 12) {
                Button(action: model.saveTranslationToGlossary) {
                    Label(model.translationSaved ? "已加入术语手册" : "加入术语手册",
                          systemImage: model.translationSaved ? "checkmark" : "book.closed")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(model.translationSaved ? Color.secondary : Color.accent)
                .disabled(!model.canSaveTranslation || model.translationSaved)
                Spacer(minLength: 0)
                if model.isTranslating {
                    Button("停止", action: model.cancelTranslation)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    if !model.translationText.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.translationTerm + "\n\n" + model.translationText, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("复制翻译").accessibilityLabel("复制翻译")
                    }
                    Button(action: model.retryTranslation) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("重新翻译").accessibilityLabel("重新翻译")
                }
            }.padding(.horizontal, 18).frame(height: 48).background(Color.workbenchChrome)
        }
        .frame(width: 400).background(Color.paper)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "inkread-page" else { return .systemAction }
            guard let value = url.host, let page = Int(value),
                  page > 0, page <= (model.selectedBook?.pageCount ?? 0) else { return .discarded }
            model.navigate(to: page - 1)
            return .handled
        })
    }
}
