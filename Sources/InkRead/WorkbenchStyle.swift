import SwiftUI
import AppKit

extension Color {
    static let workbenchSidebar = Color(nsColor: NSColor(name: "WorkbenchSidebar") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.105, green: 0.115, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.955, green: 0.956, blue: 0.95, alpha: 1)
    })
    static let workbenchChrome = Color(nsColor: NSColor(name: "WorkbenchChrome") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.135, alpha: 1)
            : NSColor(srgbRed: 0.975, green: 0.975, blue: 0.97, alpha: 1)
    })
    static let workbenchCanvas = Color(nsColor: .underPageBackgroundColor)
}

struct WorkbenchHairline: View {
    var body: some View { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 0.5) }
}

struct WorkbenchIcon: View {
    let title: String
    let symbol: String
    var active = false
    var enabled = true
    let action: () -> Void
    @State private var hovered = false
    init(_ title: String, symbol: String, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.enabled = enabled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.accent : .secondary).frame(width: 25, height: 26)
                .background(active ? Color.accent.opacity(0.12) : hovered ? Color.secondary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(title).accessibilityLabel(title).onHover { hovered = $0 }
    }
}

struct PaneDivider: View {
    @Binding var width: CGFloat
    var limits: ClosedRange<CGFloat>
    var reversed = false
    @State private var start: CGFloat?
    @State private var hovered = false
    var body: some View {
        Rectangle().fill(hovered ? Color.accent.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.5))
            .frame(width: 1).overlay { Color.clear.frame(width: 7).contentShape(Rectangle()) }
            .onHover { inside in
                hovered = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if start == nil { start = width }
                width = min(limits.upperBound, max(limits.lowerBound, (start ?? width) + value.translation.width * (reversed ? -1 : 1)))
            }.onEnded { _ in start = nil })
            .accessibilityLabel("调整面板宽度")
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }.font(.system(size: 12)).padding(9).background(Color.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }
}
