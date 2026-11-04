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
                Button("导出本书笔记…", action: model.exportNotes)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedBook == nil)
            }
            CommandMenu("阅读") {
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
