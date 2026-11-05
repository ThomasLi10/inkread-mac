import Foundation
import CodexBridge

extension AppModel {
    var selectedModelDescriptor: CodexModelDescriptor? {
        let model = selectedCodexModel.isEmpty ? configuredModelName : selectedCodexModel
        if let model { return availableModels.first { $0.model == model || $0.id == model } }
        return availableModels.first(where: \.isDefault)
    }
    var availableEfforts: [CodexReasoningEffort] { selectedModelDescriptor?.supportedReasoningEfforts ?? [] }
    var modelSelectionTitle: String {
        selectedCodexModel.isEmpty ? "Codex 默认" : (selectedModelDescriptor?.displayName ?? selectedCodexModel)
    }
    var effortSelectionTitle: String { selectedCodexEffort.isEmpty ? "默认 effort" : selectedCodexEffort }

    func selectCodexModel(_ value: String) {
        guard !isBusy else { return }
        selectedCodexModel = value
        // Effort belongs to a model's capabilities. Preserve a compatible
        // explicit choice; otherwise use that model's own default.
        if !selectedCodexEffort.isEmpty,
           !availableEfforts.contains(where: { $0.reasoningEffort == selectedCodexEffort }) {
            selectedCodexEffort = ""
        }
    }
    func selectCodexEffort(_ value: String) {
        guard !isBusy, value.isEmpty || availableEfforts.contains(where: { $0.reasoningEffort == value }) else { return }
        selectedCodexEffort = value
    }
    func refreshCodexModels() {
        guard !isLoadingModels, let store else { return }
        isLoadingModels = true; modelLoadingError = nil
        let requestID = UUID(); modelListRequestID = requestID
        // Catalog discovery submits no prompt and starts no discussion.
        let workspace = selectedBook.map { store.workspaceURL(for: $0) } ?? store.rootURL
        modelListTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.modelListRequestID == requestID { self.isLoadingModels = false } }
            do {
                let models = try await self.catalogClient.listModels(workspaceURL: workspace)
                guard !Task.isCancelled, self.modelListRequestID == requestID else { return }
                self.availableModels = models
                self.configuredModelName = self.catalogClient.configuredModel
                self.configuredModelEffort = self.catalogClient.configuredEffort
                if self.selectedModelDescriptor != nil, !self.selectedCodexEffort.isEmpty,
                   !self.availableEfforts.contains(where: { $0.reasoningEffort == self.selectedCodexEffort }) {
                    self.notice = "当前模型不再支持 \(self.selectedCodexEffort)，已恢复默认 effort"
                    self.selectedCodexEffort = ""
                }
                if models.isEmpty { self.modelLoadingError = "本机 Codex 没有返回可选模型。可刷新重试，或继续使用 Codex 默认配置。" }
                else if !self.selectedCodexModel.isEmpty && self.selectedModelDescriptor == nil {
                    self.modelLoadingError = "已保存的模型 \(self.selectedCodexModel) 不在当前列表中，请重新选择。"
                }
            } catch {
                guard !Task.isCancelled, self.modelListRequestID == requestID else { return }
                self.modelLoadingError = "读取模型列表失败：\(error.localizedDescription)"
            }
        }
    }
}
