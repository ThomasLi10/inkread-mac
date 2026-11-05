import SwiftUI
import CodexBridge

/// The same choices are available beside a question and in Settings. Model
/// capabilities come from the user's installed Codex, including future efforts.
struct CodexGenerationControls: View {
    @ObservedObject var model: AppModel
    var settings = false

    var body: some View {
        VStack(alignment: .leading, spacing: settings ? 9 : 0) {
            HStack(spacing: settings ? 12 : 9) {
                if settings { Text("模型").foregroundStyle(.secondary).frame(width: 40, alignment: .leading) }
                modelMenu
                    .frame(maxWidth: settings ? .infinity : 190, alignment: .leading)
                if !settings { Spacer(minLength: 0) }
                effortMenu
                if settings { refreshButton }
            }
            .font(.system(size: settings ? 13 : 11.5))
            .frame(minHeight: settings ? 25 : 22)
            if settings {
                if model.isLoadingModels {
                    Label("正在读取本机 Codex 的模型列表…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let error = model.modelLoadingError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                } else {
                    Text("应用于下一次讨论、翻译与辅助整理。默认选项使用 Codex 的配置；effort 表示推理投入。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if model.availableModels.isEmpty && model.modelLoadingError == nil { model.refreshCodexModels() }
        }
    }

    private var modelMenu: some View {
        Menu {
            Button { model.selectCodexModel("") } label: {
                choiceLabel("Codex 默认", selected: model.selectedCodexModel.isEmpty)
            }
            if !model.availableModels.isEmpty {
                Divider()
                ForEach(model.availableModels) { item in
                    Button { model.selectCodexModel(item.model) } label: {
                        choiceLabel(item.displayName, selected: model.selectedCodexModel == item.model)
                    }.help(item.description)
                }
            } else if model.isLoadingModels {
                Text("正在读取模型列表…")
            } else if model.modelLoadingError != nil {
                Text("模型列表读取失败，请刷新")
            }
            Divider()
            Button(model.isLoadingModels ? "正在刷新…" : "刷新模型列表", action: model.refreshCodexModels)
                .disabled(model.isLoadingModels || model.isBusy)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 11))
                Text(model.modelSelectionTitle).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .disabled(model.isBusy)
        .help("Codex 模型：\(model.modelSelectionTitle)")
        .accessibilityLabel("Codex 模型：\(model.modelSelectionTitle)")
    }

    private var effortMenu: some View {
        Menu {
            Button { model.selectCodexEffort("") } label: {
                choiceLabel("默认 effort", selected: model.selectedCodexEffort.isEmpty)
            }
            if !model.availableEfforts.isEmpty {
                Divider()
                ForEach(model.availableEfforts) { item in
                    Button { model.selectCodexEffort(item.reasoningEffort) } label: {
                        choiceLabel(item.reasoningEffort, selected: model.selectedCodexEffort == item.reasoningEffort)
                    }.help(item.description)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                Text(model.effortSelectionTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(model.isBusy)
        .help("推理 effort：\(model.effortSelectionTitle)")
        .accessibilityLabel("Codex effort：\(model.effortSelectionTitle)")
    }

    private var refreshButton: some View {
        Button(action: model.refreshCodexModels) {
            if model.isLoadingModels { ProgressView().controlSize(.mini) }
            else { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .frame(width: 23, height: 23)
        .disabled(model.isLoadingModels || model.isBusy)
        .help("刷新本机 Codex 支持的模型与 effort")
        .accessibilityLabel("刷新模型列表")
    }

    @ViewBuilder
    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }
}
