import SwiftUI
import AppKit

/// Native, selectable Markdown blocks. Parsing an unfinished fence is intentional:
/// the same code block grows as Codex streams rather than flashing between formats.
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownMessageParser.blocks(in: text)) { block in
                switch block.content {
                case .paragraph(let value): inline(value)
                case .heading(let level, let value):
                    inline(value)
                        .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: .semibold))
                        .padding(.top, block.line == 0 ? 0 : 4)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.marker).font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                                inline(item.text).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.leading, CGFloat(min(item.indent, 4)) * 12)
                        }
                    }
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.25)).frame(width: 2)
                        inline(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    InspectorCodeBlock(language: language, code: code)
                case .table(let table):
                    InspectorMarkdownTable(table: table)
                case .rule:
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(height: 1).padding(.vertical, 2)
                }
            }
        }
        .font(.system(size: 14))
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ value: String) -> Text {
        Text(InspectorInlineMarkdown.attributed(value))
    }
}

private enum InspectorInlineMarkdown {
    static func attributed(_ value: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 12.5, design: .monospaced)
        }
        // Add navigation attributes after Markdown parsing. This leaves the raw
        // reply untouched and preserves existing web links (including a link
        // whose visible label itself contains a bracketed page citation).
        let plain = String(attributed.characters)
        if let expression = try? NSRegularExpression(pattern: #"\[PDF\s*第\s*([0-9]+)\s*页\]"#) {
            for match in expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let textRange = Range(match.range, in: plain),
                      let numberRange = Range(match.range(at: 1), in: plain),
                      let page = Int(plain[numberRange]), page > 0 else { continue }
                let offset = plain.distance(from: plain.startIndex, to: textRange.lowerBound)
                let count = plain.distance(from: textRange.lowerBound, to: textRange.upperBound)
                let lower = attributed.characters.index(attributed.startIndex, offsetBy: offset)
                let upper = attributed.characters.index(lower, offsetBy: count)
                let range = lower..<upper
                let isLiteralOrLinked = attributed[range].runs.contains {
                    $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true
                }
                if !isLiteralOrLinked { attributed[range].link = URL(string: "inkread-page://\(page)") }
            }
        }
        return attributed
    }
}

private struct InspectorMarkdownTable: View {
    let table: MarkdownMessageParser.Table
    @State private var copied = false

    private var columnWidths: [CGFloat] {
        table.header.indices.map { column in
            let values = [table.header[column]] + table.rows.map { $0[column] }
            let widest = values.map {
                NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width
            }.max() ?? 80
            return min(210, max(80, ceil(widest)))
        }
    }

    var body: some View {
        let widths = columnWidths
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("表格").foregroundStyle(.tertiary)
                Spacer()
                Button {
                    copy(table.markdown)
                } label: {
                    Label(copied ? "已复制" : "复制表格", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .contextMenu {
                    Button("复制 Markdown 表格") { copy(table.markdown) }
                    Button("复制为制表符分隔文本") {
                        let rows = [table.header] + table.rows
                        copy(rows.map { row in
                            row.map { $0.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "\t", with: " ") }
                                .joined(separator: "\t")
                        }.joined(separator: "\n"))
                    }
                }
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    if !Task.isCancelled { copied = false }
                }
            }.font(.system(size: 10.5))
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow(alignment: .top) {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(table.header[column], column: column, width: widths[column], heading: true)
                        }
                    }
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(height: 0.5)
                        .gridCellUnsizedAxes(.horizontal)
                    ForEach(table.rows.indices, id: \.self) { row in
                        GridRow(alignment: .top) {
                            ForEach(table.header.indices, id: \.self) { column in
                                cell(table.rows[row][column], column: column, width: widths[column], heading: false)
                            }
                        }
                        .background(row.isMultiple(of: 2) ? Color.clear : Color(nsColor: .quaternaryLabelColor).opacity(0.13))
                        if row < table.rows.count - 1 {
                            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.3)).frame(height: 0.5)
                                .gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
                .padding(.bottom, 2)
            }
        }
    }

    private func cell(_ value: String, column: Int, width: CGFloat, heading: Bool) -> some View {
        let attributed = InspectorInlineMarkdown.attributed(value)
        let alignment: Alignment = table.alignments[column] == .center ? .center : table.alignments[column] == .trailing ? .trailing : .leading
        return Text(attributed).font(.system(size: 12, weight: heading ? .semibold : .regular))
            .lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: alignment).padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
    }
}

private struct InspectorCodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("复制代码")
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        if !Task.isCancelled { copied = false }
                    }
            }.padding(.horizontal, 11).padding(.vertical, 8)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45)).frame(height: 1)
            ScrollView(.horizontal) {
                Text(verbatim: code.isEmpty ? " " : code)
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }
}

private enum MarkdownMessageParser {
    struct Block: Identifiable {
        let line: Int
        let content: Content
        var id: Int { line }
    }

    struct ListItem: Identifiable {
        let id: Int
        let marker: String
        let text: String
        let indent: Int
    }

    enum ColumnAlignment: Equatable { case leading, center, trailing }

    struct Table {
        let header: [String]
        let alignments: [ColumnAlignment]
        let rows: [[String]]
        let markdown: String
    }

    enum Content {
        case paragraph(String)
        case heading(Int, String)
        case list([ListItem])
        case quote(String)
        case code(String, String)
        case table(Table)
        case rule
    }

    static func blocks(in text: String) -> [Block] {
        let lines = text.components(separatedBy: .newlines)
        var output: [Block] = []
        var index = 0
        while index < lines.count {
            let start = index
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if let fence = fenceMarker(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                index += 1
                var code: [String] = []
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { index += 1; break }
                    code.append(lines[index]); index += 1
                }
                output.append(Block(line: start, content: .code(language, code.joined(separator: "\n"))))
                continue
            }
            if let (header, alignments) = tableStart(lines, at: index) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]) {
                    rows.append(cells)
                    index += 1
                }
                // Keep extra cells from imperfect/streaming rows rather than
                // truncating them to the header's original column count.
                let count = max(header.count, rows.map(\.count).max() ?? 0)
                func padded(_ row: [String]) -> [String] { row + Array(repeating: "", count: count - row.count) }
                let table = Table(header: padded(header),
                    alignments: alignments + Array(repeating: .leading, count: count - alignments.count),
                    rows: rows.map(padded), markdown: lines[start..<index].joined(separator: "\n"))
                output.append(Block(line: start, content: .table(table)))
                continue
            }
            if let heading = heading(trimmed) {
                output.append(Block(line: start, content: .heading(heading.0, heading.1)))
                index += 1; continue
            }
            if isRule(trimmed) { output.append(Block(line: start, content: .rule)); index += 1; continue }
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                output.append(Block(line: start, content: .quote(quote.joined(separator: "\n"))))
                continue
            }
            if listItem(lines[index], line: index) != nil {
                var items: [ListItem] = []
                while index < lines.count, let item = listItem(lines[index], line: index) {
                    items.append(item); index += 1
                }
                output.append(Block(line: start, content: .list(items))); continue
            }
            var paragraph: [String] = []
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.isEmpty || (index > start && (fenceMarker(line) != nil || heading(line) != nil || line.hasPrefix(">") || isRule(line) || listItem(lines[index], line: index) != nil || tableStart(lines, at: index) != nil)) { break }
                paragraph.append(line); index += 1
            }
            output.append(Block(line: start, content: .paragraph(paragraph.joined(separator: "\n"))))
        }
        return output
    }

    private static func tableStart(_ lines: [String], at index: Int) -> ([String], [ColumnAlignment])? {
        guard index + 1 < lines.count, let header = tableCells(lines[index]),
              let separators = tableCells(lines[index + 1]), header.count == separators.count else { return nil }
        var alignments: [ColumnAlignment] = []
        for cell in separators {
            var marker = cell.filter { !$0.isWhitespace }
            let leading = marker.hasPrefix(":")
            let trailing = marker.hasSuffix(":")
            if leading { marker.removeFirst() }
            if trailing, !marker.isEmpty { marker.removeLast() }
            guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return (header, alignments)
    }

    /// Split actual delimiters, preserving empty columns, escaped pipes and pipes
    /// inside inline code. Leading/trailing table bars are optional.
    private static func tableCells(_ raw: String) -> [String]? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        var cells: [String] = []
        var current = ""
        var index = line.startIndex
        var codeTicks = 0
        var delimiters = 0
        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                current.append(character)
                index = line.index(after: index)
                if index < line.endIndex { current.append(line[index]); index = line.index(after: index) }
                continue
            }
            if character == "`" {
                var end = index
                while end < line.endIndex, line[end] == "`" { end = line.index(after: end) }
                let count = line.distance(from: index, to: end)
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                current += String(line[index..<end]); index = end; continue
            }
            if character == "|", codeTicks == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; delimiters += 1
            } else { current.append(character) }
            index = line.index(after: index)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        guard delimiters > 0 else { return nil }
        if line.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
        if line.hasSuffix("|"), cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func fenceMarker(_ line: String) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = String(line.prefix(while: { $0 == first }))
        return marker.count >= 3 ? marker : nil
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let prefix = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).first?.isWhitespace == true else { return nil }
        return (prefix.count, String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        return compact.count >= 3 && (compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" })
    }

    private static func listItem(_ line: String, line number: Int) -> ListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
        if let first = trimmed.first, ["-", "+", "*"].contains(String(first)), trimmed.dropFirst().first?.isWhitespace == true {
            return ListItem(id: number, marker: "•", text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), indent: indent)
        }
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, let delimiter = trimmed.dropFirst(digits.count).first,
              delimiter == "." || delimiter == ")",
              trimmed.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
        return ListItem(id: number, marker: String(digits) + ".", text: String(trimmed.dropFirst(digits.count + 1)).trimmingCharacters(in: .whitespaces), indent: indent)
    }
}
