import SwiftUI
import AppKit

@main
struct InkReadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("墨读") {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 720)
                .tint(Color.accent)
                .onAppear(perform: model.applyAppearance)
                .onOpenURL { model.importPDFs([$0]) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入 PDF…", action: model.choosePDFs)
                    .keyboardShortcut("o")
                Button("新讨论") { model.startDiscussion() }.keyboardShortcut("n").disabled(model.selectedBook == nil || model.isBusy)
                Button("导出本书笔记…", action: model.exportNotes)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedBook == nil)
            }
            CommandMenu("工作台") {
                Button("命令面板") { model.showCommandPalette.toggle() }.keyboardShortcut("k")
                Button("查找 PDF 原文", action: model.openPDFSearch).keyboardShortcut("f").disabled(model.selectedBook == nil)
                Button("下一处匹配") { model.performReader(.nextMatch) }.keyboardShortcut("g")
                Button("上一处匹配") { model.performReader(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("打开目录", action: model.openOutline).keyboardShortcut("o", modifiers: [.command, .shift])
                Button("切换导航栏") { model.showNavigation.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("切换讨论面板") { model.showInspector.toggle() }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("专注阅读", action: model.toggleFocusMode).keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("阅读") {
                Button("放大") { model.performReader(.zoomIn) }.keyboardShortcut("+")
                Button("缩小") { model.performReader(.zoomOut) }.keyboardShortcut("-")
                Button("实际大小") { model.performReader(.actualSize) }.keyboardShortcut("0")
                Button("适合宽度") { model.performReader(.fitWidth) }.keyboardShortcut("1")
                Button("整页显示") { model.performReader(.fitPage) }.keyboardShortcut("2")
                Divider()
                Button("选区加入上下文篮", action: model.addSelectionToContext).keyboardShortcut("c", modifiers: [.command, .shift])
                Button("为选区添加彩色批注") { model.openAnnotationEditor() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("固定参考页", action: model.pinSelection).keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("上一页") { model.turnPage(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("下一页") { model.turnPage(1) }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("讨论选中内容") { model.startDiscussion() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("保存为笔记") { model.openNoteEditor() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("外观") {
                Picker("应用外观", selection: $model.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Divider()
                Toggle("深色时反转 PDF 颜色", isOn: $model.invertPDFInDarkMode)
            }
        }
        Settings { SettingsView(model: model).frame(width: 580, height: 430).padding(24).tint(Color.accent) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--smoke-test") {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
            return
        }
        if ProcessInfo.processInfo.environment["INKREAD_BACKGROUND_TEST"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Color {
    static let accent = Color(nsColor: NSColor(name: "InkReadAccent") { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.42, green: 0.77, blue: 0.69, alpha: 1)
        }
        return NSColor(srgbRed: 0.12, green: 0.39, blue: 0.36, alpha: 1)
    })
    static let onAccent = Color(nsColor: NSColor(name: "InkReadOnAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.06, green: 0.15, blue: 0.13, alpha: 1) : .white
    })
    static let paper = Color(nsColor: .textBackgroundColor)
}
