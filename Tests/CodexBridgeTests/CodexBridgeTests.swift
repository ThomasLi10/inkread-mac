import XCTest
@testable import CodexBridge

final class CodexBridgeTests: XCTestCase {
    func testFramingPreservesSplitUTF8AndCRLF() throws {
        var framer = JSONLineFramer()
        let bytes = Array("{\"text\":\"中文\"}\r\n{\"id\":2}\n".utf8)
        var lines: [Data] = []
        for byte in bytes { lines += try framer.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: lines[0]) as? [String: String])
        XCTAssertEqual(first["text"], "中文")
    }

    func testFramingBoundsUnterminatedAndOversizeMessages() {
        var framer = JSONLineFramer(maximumLineBytes: 4)
        XCTAssertThrowsError(try framer.append(Data("12345".utf8)))
        var another = JSONLineFramer(maximumLineBytes: 4)
        XCTAssertThrowsError(try another.append(Data("12345\n".utf8)))
    }

    func testTranscriptCompletedFallbackDoesNotDuplicateStreamedText() {
        var transcript = AgentTranscript()
        XCTAssertEqual(transcript.append(id: "one", delta: "你好"), "你好")
        XCTAssertEqual(transcript.complete(id: "one", text: "你好，世界"), "，世界")
        XCTAssertEqual(transcript.complete(id: "two", text: "结论"), "\n\n结论")
        XCTAssertEqual(transcript.text, "你好，世界\n\n结论")
        XCTAssertEqual(transcript.complete(id: "one", text: "修正"), "")
        XCTAssertEqual(transcript.text, "修正\n\n结论")
    }

    func testStderrRedactionAcrossReadBoundariesAndBoundedStorage() {
        var log = RedactedLogBuffer()
        XCTAssertEqual(log.append(Data("Authorization: Bear".utf8)), "")
        let result = log.append(Data("er secret-value\napi_key=sk-secretkey123456789\n".utf8))
        XCTAssertFalse(result.contains("secret-value"))
        XCTAssertFalse(result.contains("sk-secretkey"))
        let bounded = log.append(Data((String(repeating: "x", count: 10_000) + "\n").utf8))
        XCTAssertLessThanOrEqual(bounded.count, 4096)
        XCTAssertTrue(bounded.contains("已省略"))
    }

    @MainActor
    func testFakeProcessStreamsAndReusesPersistedThreadWithExplicitReadOnlyPolicy() async throws {
        let fixture = try FakeServer(mode: "stream")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        var threadID: String?
        var streamed = ""
        let first = try await client.respond(threadID: nil, prompt: "解释这一段", imageURL: fixture.workspace.appendingPathComponent("figure.png"), workspaceURL: fixture.workspace, onThread: { threadID = $0 }, onDelta: { streamed += $0 }, onActivity: { _ in })
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(first, "你好，世界")
        XCTAssertEqual(streamed, first)
        let second = try await client.respond(threadID: threadID, prompt: "继续", imageURL: nil, workspaceURL: fixture.workspace, onThread: { _ in }, onDelta: { _ in }, onActivity: { _ in })
        XCTAssertEqual(second, first)
        XCTAssertFalse(client.isRunning)
        let messages = try fixture.requests()
        XCTAssertEqual(messages.filter { $0["method"] as? String == "initialize" }.count, 1)
        let resumed = try XCTUnwrap(messages.first { $0["method"] as? String == "thread/resume" }?["params"] as? [String: Any])
        XCTAssertEqual(resumed["sandbox"] as? String, "read-only")
        XCTAssertEqual(resumed["approvalPolicy"] as? String, "never")
        let config = try XCTUnwrap(resumed["config"] as? [String: Any])
        let servers = try XCTUnwrap(config["mcp_servers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["unsafe"]?["enabled"] as? Bool, false)
        XCTAssertEqual(servers["unsafe"]?["command"] as? String, "/usr/bin/false")
        let turn = try XCTUnwrap(messages.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual((turn["sandboxPolicy"] as? [String: Any])?["type"] as? String, "readOnly")
        XCTAssertEqual((turn["sandboxPolicy"] as? [String: Any])?["networkAccess"] as? Bool, false)
        XCTAssertNil(turn["model"])
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["type"] as? String, "localImage")
    }

    @MainActor
    func testFakeProcessCompletedItemFallbackAndReconnect() async throws {
        let fixture = try FakeServer(mode: "fallback")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        var thread: String?
        let first = try await respond(client, fixture: fixture, onThread: { thread = $0 })
        XCTAssertEqual(first, "最终答案")
        client.shutdown()
        let second = try await respond(client, fixture: fixture, threadID: thread)
        XCTAssertEqual(second, first)
        XCTAssertEqual(try fixture.requests().filter { $0["method"] as? String == "initialize" }.count, 2)
    }

    @MainActor
    func testFakeProcessFailureAndExitNeverReturnPartialAnswerAsSuccess() async throws {
        for mode in ["failed", "processExit", "unsafePolicy", "unsafeMCP"] {
            let fixture = try FakeServer(mode: mode)
            defer { fixture.remove() }
            let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
            defer { client.shutdown() }
            do {
                _ = try await respond(client, fixture: fixture)
                XCTFail("\(mode) should fail")
            } catch {
                XCTAssertFalse(client.isRunning)
                switch mode {
                case "failed": XCTAssertEqual(error as? CodexBridgeError, .server("expected failure"))
                case "unsafePolicy": XCTAssertEqual(error as? CodexBridgeError, .protocolFailure("服务端没有采用只读权限"))
                case "unsafeMCP": XCTAssertEqual(error as? CodexBridgeError, .protocolFailure("外部 MCP 未完全禁用，已停止连接"))
                default:
                    guard case .server(let message) = error as? CodexBridgeError else { return XCTFail("Unexpected error: \(error)") }
                    XCTAssertTrue(message.contains("9"))
                }
            }
        }
    }

    @MainActor
    func testFakeProcessApprovalIsRejectedAndDoesNotHang() async throws {
        let fixture = try FakeServer(mode: "approval")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        do {
            _ = try await respond(client, fixture: fixture)
            XCTFail("Approval must stop this read-only reader")
        } catch {
            XCTAssertEqual(error as? CodexBridgeError, .unsupportedRequest("item/fileChange/requestApproval"))
        }
        XCTAssertFalse(client.isRunning)
    }

    @MainActor
    func testFakeProcessInitializationAndTurnTimeouts() async throws {
        for mode in ["initializeTimeout", "turnTimeout"] {
            let fixture = try FakeServer(mode: mode)
            defer { fixture.remove() }
            let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: mode == "initializeTimeout" ? 0.15 : 2, turnTimeout: 0.15)
            defer { client.shutdown() }
            do {
                _ = try await respond(client, fixture: fixture)
                XCTFail("\(mode) should time out")
            } catch {
                guard case .timedOut = error as? CodexBridgeError else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertFalse(client.isRunning)
        }
    }

    @MainActor
    func testFakeProcessTaskCancellationStopsTheOwnedProcess() async throws {
        let fixture = try FakeServer(mode: "turnTimeout")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 20)
        defer { client.shutdown() }
        var started = false
        let task = Task { @MainActor in
            try await client.respond(threadID: nil, prompt: "test", imageURL: nil, workspaceURL: fixture.workspace, onThread: { _ in started = true }, onDelta: { _ in }, onActivity: { _ in })
        }
        for _ in 0..<100 {
            if started { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? CodexBridgeError == .interrupted) }
        XCTAssertFalse(client.isRunning)
    }

    @MainActor
    private func respond(_ client: CodexClient, fixture: FakeServer, threadID: String? = nil, onThread: @escaping (String) -> Void = { _ in }) async throws -> String {
        do {
            return try await client.respond(threadID: threadID, prompt: "test", imageURL: nil, workspaceURL: fixture.workspace, onThread: onThread, onDelta: { _ in }, onActivity: { _ in })
        } catch {
            if !client.diagnosticLog.isEmpty { print("Fake server diagnostic: \(client.diagnosticLog)") }
            throw error
        }
    }
}

private struct FakeServer {
    let workspace: URL
    let executable: URL
    private let requestLog: URL

    init(mode: String) throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("InkRead-CodexBridge-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        executable = workspace.appendingPathComponent("fake-codex")
        requestLog = workspace.appendingPathComponent("requests.jsonl")
        func literal(_ value: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        }
        let script = """
        #!/usr/bin/python3
        import sys,json,time,os
        mode=\(literal(mode))
        logfile=\(literal(requestLog.path))
        def emit(value):
            payload=(json.dumps(value,ensure_ascii=False)+'\\n').encode('utf-8')
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.flush()
        def reply(req,value): emit({'id':req['id'],'result':value})
        def note(method,params): emit({'method':method,'params':params})
        for line in sys.stdin:
            req=json.loads(line)
            with open(logfile,'a') as f: f.write(json.dumps(req)+'\\n')
            method=req.get('method')
            if method=='initialize':
                if mode=='initializeTimeout': continue
                reply(req,{'userAgent':'fake'})
            elif method=='config/read': reply(req,{'config':{'mcp_servers':{'unsafe':{'command':'not-run','enabled':True}}}})
            elif method in ['thread/start','thread/resume']:
                reply(req,{'thread':{'id':'thread-1'},'sandbox':{'type':'dangerFullAccess' if mode=='unsafePolicy' else 'readOnly'},'approvalPolicy':'never'})
            elif method=='mcpServerStatus/list':
                reply(req,{'data':[{'name':'unsafe','runtimeStatus':'ready' if mode=='unsafeMCP' else 'disabled','tools':{'bad':{}} if mode=='unsafeMCP' else {}}],'nextCursor':None})
            elif method=='turn/start':
                reply(req,{'turn':{'id':'turn-1','status':'inProgress','items':[]}})
                if mode=='processExit': sys.exit(9)
                if mode=='turnTimeout': continue
                if mode=='approval':
                    emit({'id':'approve-1','method':'item/fileChange/requestApproval','params':{'threadId':'thread-1','turnId':'turn-1'}})
                    continue
                if mode=='stream':
                    note('item/agentMessage/delta',{'threadId':'other-thread','turnId':'wrong','itemId':'wrong','delta':'不应出现'})
                    note('item/agentMessage/delta',{'threadId':'thread-1','turnId':'turn-1','itemId':'answer-1','delta':'你好'})
                    note('item/completed',{'threadId':'thread-1','turnId':'turn-1','item':{'type':'agentMessage','id':'answer-1','text':'你好，世界'}})
                items=[] if mode=='stream' else [{'type':'agentMessage','id':'answer-1','text':'最终答案'}]
                turn={'id':'turn-1','status':'failed' if mode=='failed' else 'completed','items':items}
                if mode=='failed': turn['error']={'message':'expected failure'}
                note('turn/completed',{'threadId':'thread-1','turn':turn})
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func requests() throws -> [[String: Any]] {
        try String(contentsOf: requestLog).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    func remove() { try? FileManager.default.removeItem(at: workspace) }
}
