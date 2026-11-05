import SwiftUI
import AppKit

struct NoteEditor: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil").foregroundStyle(Color.accent)
                Text(model.editingNote == nil ? "新建阅读笔记" : "编辑阅读笔记").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("MARKDOWN").font(.system(size: 10, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
            }.padding(.horizontal, 24).frame(height: 55)
            WorkbenchHairline()
            TextField("笔记标题", text: $model.noteTitle).textFieldStyle(.plain).font(.system(size: 21, weight: .medium))
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)
            TextEditor(text: $model.noteBody).font(.system(size: 14, design: .monospaced)).lineSpacing(5)
                .scrollContentBackground(.hidden).padding(.horizontal, 19).padding(.bottom, 18).frame(maxHeight: .infinity)
            WorkbenchHairline()
            HStack {
                Label("保留原文引用", systemImage: "link").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.showNoteEditor = false }.keyboardShortcut(.cancelAction)
                Button("保存", action: model.saveNote).buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent).keyboardShortcut(.defaultAction)
                    .disabled(model.noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 24).frame(height: 59).background(Color.workbenchChrome)
        }.frame(width: 650, height: 520).background(Color.paper)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("阅读外观") {
                Picker("应用外观", selection: $model.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
                Toggle("深色时反转 PDF 颜色", isOn: $model.invertPDFInDarkMode)
                Text("将白底黑字显示为深底浅字。彩色图片也会反转，可随时关闭以查看原色。原文件与发送给 Codex 的截图保持原色。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("本地 Codex") {
                CodexGenerationControls(model: model, settings: true)
                TextField("可执行文件路径（留空自动查找）", text: $model.codexPath)
                    .disabled(model.isBusy || model.isTranslating)
                HStack {
                    Button("选择 Codex…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { model.codexPath = url.path; model.applyCodexPath() }
                    }
                    Button("应用设置", action: model.applyCodexPath)
                }
                .disabled(model.isBusy || model.isTranslating)
                Text("复用 Codex 自己的登录。提交的选段与图表会发往所用模型服务；阅读副本、笔记和讨论保存在本机。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("墨读使用临时会话，阅读讨论只保存在墨读书库，不进入 Codex 的最近会话列表。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("书库") {
                Button("在 Finder 中打开本地书库") {
                    if let root = model.store?.rootURL { NSWorkspace.shared.open(root) }
                }
            }
        }.formStyle(.grouped)
    }
}
