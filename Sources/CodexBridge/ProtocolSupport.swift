import Foundation

public enum CodexBridgeError: LocalizedError, Equatable {
    case executableNotFound
    case busy
    case disconnected
    case timedOut(String)
    case protocolFailure(String)
    case server(String)
    case unsupportedRequest(String)
    case interrupted

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "没有找到 Codex CLI，请在设置中选择已安装的 codex 可执行文件。"
        case .busy: return "Codex 正在回答上一个问题，请等待或先停止。"
        case .disconnected: return "Codex 进程已断开。讨论已保留，可以重新发送问题以续接会话。"
        case .timedOut(let operation): return "Codex \(operation)超时，连接已停止。可以稍后重试。"
        case .protocolFailure(let message): return "Codex 协议错误：\(message)"
        case .server(let message): return "Codex：\(message)"
        case .unsupportedRequest(let method): return "阅读器已拒绝 Codex 的交互或权限请求（\(method)）。本次回答已停止。"
        case .interrupted: return "回答已停止。"
        }
    }
}

/// Frames bytes before decoding UTF-8, so a split Chinese character is never lost.
struct JSONLineFramer {
    private var buffer = Data()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 16 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let count = buffer.distance(from: buffer.startIndex, to: newline)
            guard count <= maximumLineBytes else {
                throw CodexBridgeError.protocolFailure("单条消息过大")
            }
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= maximumLineBytes else {
            throw CodexBridgeError.protocolFailure("未完成的消息过大")
        }
        return lines
    }
}

/// The completed item is authoritative; deltas are only the streaming preview.
struct AgentTranscript {
    private var order: [String] = []
    private var messages: [String: String] = [:]

    mutating func append(id: String, delta: String) -> String {
        let separator = begin(id)
        messages[id, default: ""] += delta
        return separator + delta
    }

    mutating func complete(id: String, text: String) -> String {
        let separator = begin(id)
        let previous = messages[id, default: ""]
        messages[id] = text
        if text.hasPrefix(previous) { return separator + String(text.dropFirst(previous.count)) }
        // A correction cannot be expressed as an append. The final returned value
        // replaces the preview in the app's model after the turn finishes.
        return previous.isEmpty ? separator + text : ""
    }

    var text: String { order.compactMap { messages[$0] }.filter { !$0.isEmpty }.joined(separator: "\n\n") }

    private mutating func begin(_ id: String) -> String {
        guard messages[id] == nil else { return "" }
        let separator = text.isEmpty ? "" : "\n\n"
        order.append(id)
        messages[id] = ""
        return separator
    }
}

enum BridgeRedaction {
    static func clean(_ value: String, limit: Int = 1600) -> String {
        var output = value
        let patterns = [
            "(?i)(authorization[\\\"':=\\s]+(?:bearer\\s+)?)[^\\s\\\",}]+",
            "(?i)((?:access_token|refresh_token|id_token|api_key|token|password|cookie)[\\\"':=\\s]+)[^\\s\\\",}]+",
            "\\bsk-[A-Za-z0-9_-]{8,}",
            "\\beyJ[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)?"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let template = regex.numberOfCaptureGroups > 0 ? "$1[已隐藏]" : "[已隐藏]"
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: template)
        }
        return String(output.prefix(limit))
    }
}

/// Redact whole stderr lines, including secrets split across pipe reads. Oversize
/// lines are discarded; raw partial lines are never published or written to disk.
struct RedactedLogBuffer {
    private var line = Data()
    private var discarding = false
    private var log = ""

    mutating func append(_ data: Data) -> String {
        for byte in data {
            if byte == 0x0A {
                if discarding { log += "[过长诊断行已省略]\n" }
                else { log += BridgeRedaction.clean(String(decoding: line, as: UTF8.self)) + "\n" }
                log = String(log.suffix(4096))
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count < 8192 { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return log
    }
}
