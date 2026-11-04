import AppKit
import SwiftUI

struct WorkbenchCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let shortcut: String?
    let perform: () -> Void
}

/// A real command surface: the caller supplies available actions and owns the
/// backdrop. At most eight rows are visible; additional matches remain reachable.
struct CommandPalette: View {
    let commands: [WorkbenchCommand]
    var onDismiss: () -> Void

    @State private var search = ""
    @State private var selectedIndex = 0

    private let rowHeight: CGFloat = 39

    private var matches: [WorkbenchCommand] {
        let terms = search.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return commands }
        return commands.filter { command in
            let searchable = command.title + " " + command.subtitle
            return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
            Divider()
            keyboardHints
        }
        .frame(width: 540)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .onChange(of: search) { _, _ in selectedIndex = 0 }
        .onChange(of: matches.map(\.id)) { _, ids in
            selectedIndex = min(selectedIndex, max(0, ids.count - 1))
        }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("命令面板")
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            PaletteSearchField(text: $search, move: moveSelection,
                               submit: executeSelection, dismiss: onDismiss)
                .frame(height: 28)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除命令搜索")
            } else {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    @ViewBuilder
    private var results: some View {
        let current = matches
        if current.isEmpty {
            VStack(spacing: 8) {
                Text("没有匹配的命令").font(.system(size: 13, weight: .medium))
                Text("尝试书名、操作名称或其他关键词")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(current.enumerated()), id: \.element.id) { index, command in
                            commandRow(command, selected: index == selectedIndex)
                                .id(command.id)
                                .onHover { hovering in
                                    if hovering { selectedIndex = index }
                                }
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.hidden)
                .frame(height: CGFloat(min(8, current.count)) * rowHeight + 8)
                .onChange(of: selectedIndex) { _, index in
                    guard current.indices.contains(index) else { return }
                    proxy.scrollTo(current[index].id)
                }
                .onChange(of: search) { _, _ in
                    if let first = matches.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private func commandRow(_ command: WorkbenchCommand, selected: Bool) -> some View {
        Button { execute(command) } label: {
            HStack(spacing: 11) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.accent : Color.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !command.subtitle.isEmpty {
                        Text(command.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if let shortcut = command.shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Color.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(selected ? "已选中" : "")
    }

    private var keyboardHints: some View {
        HStack(spacing: 14) {
            hint("↑ ↓", label: "选择")
            hint("↩", label: "执行")
            hint("esc", label: "关闭")
            Spacer()
            Text("\(matches.count) 个命令")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private func hint(_ key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .medium, design: .monospaced))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    private func moveSelection(_ step: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + step), count - 1)
    }

    private func executeSelection() {
        let current = matches
        guard current.indices.contains(selectedIndex) else { return }
        execute(current[selectedIndex])
    }

    private func execute(_ command: WorkbenchCommand) {
        onDismiss()
        command.perform()
    }
}

/// Use the native field editor's command delegate so arrow keys and Return are
/// reliable while typing. IME composition retains those keys for Chinese input.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var move: (Int) -> Void
    var submit: () -> Void
    var dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PaletteSearchControl {
        let field = PaletteSearchControl()
        field.delegate = context.coordinator
        field.placeholderString = "搜索命令…"
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.setAccessibilityLabel("搜索命令")
        field.setAccessibilityHelp("输入关键词筛选，使用上下方向键选择，回车执行，Escape 关闭。")
        return field
    }

    func updateNSView(_ field: PaletteSearchControl, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // Return confirms an IME candidate; it must not execute a command too.
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(commandSelector) {
            case "moveUp:": parent.move(-1)
            case "moveDown:": parent.move(1)
            case "insertNewline:": parent.submit()
            case "cancelOperation:": parent.dismiss()
            default: return false
            }
            return true
        }
    }
}

private final class PaletteSearchControl: NSSearchField {
    private var requestedInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.requestedInitialFocus else { return }
            self.requestedInitialFocus = true
            window.makeFirstResponder(self)
        }
    }
}
