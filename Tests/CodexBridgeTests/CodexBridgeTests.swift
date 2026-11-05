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

    func testTranscriptCanRemoveAnItemWhoseCommentaryPhaseArrivesLate() {
        var transcript = AgentTranscript()
        _ = transcript.append(id: "progress", delta: "我会先核对原文")
        _ = transcript.complete(id: "answer", text: "正式答案")
        transcript.remove(id: "progress")
        XCTAssertEqual(transcript.text, "正式答案")
        transcript.remove(id: "progress")
        XCTAssertEqual(transcript.append(id: "next", delta: "后续答案"), "\n\n后续答案")
        XCTAssertEqual(transcript.text, "正式答案\n\n后续答案")
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
        XCTAssertEqual(turn["model"] as? String, "configured-model")
        XCTAssertEqual(turn["effort"] as? String, "medium")
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["type"] as? String, "localImage")
    }

    @MainActor
    func testModelCatalogPaginationPreservesFutureEffortsAndFiltersHiddenEntries() async throws {
        let fixture = try FakeServer(mode: "catalog")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        let models = try await client.listModels(workspaceURL: fixture.workspace)
        XCTAssertEqual(models.map(\.model), ["configured-model", "future-model"])
        XCTAssertEqual(models.last?.supportedReasoningEfforts.last?.reasoningEffort, "future-effort")
        XCTAssertEqual(models.last?.inputModalities, ["text", "future-modality"])
        XCTAssertFalse(models.last?.supportsImages ?? true)
        XCTAssertTrue(models.first?.supportsImages ?? false, "Omitted modalities use the protocol's text/image default")
        XCTAssertFalse(client.isRunning)
        let requests = try fixture.requests()
        let pages = requests.filter { $0["method"] as? String == "model/list" }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual((pages.last?["params"] as? [String: Any])?["cursor"] as? String, "next-page")
        XCTAssertFalse(requests.contains { ["thread/start", "thread/resume", "turn/start"].contains($0["method"] as? String ?? "") })
    }

    @MainActor
    func testModelAndEffortOverridesChangeOnResumeAndResetToCLIConfigDefaults() async throws {
        let fixture = try FakeServer(mode: "stream")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        for selection in [("future-model", "future-effort"), ("configured-model", "low"), (nil, nil)] as [(String?, String?)] {
            _ = try await client.respond(threadID: selection.0 == "future-model" ? nil : "thread-1", prompt: "继续",
                                         imageURL: nil, workspaceURL: fixture.workspace, model: selection.0, effort: selection.1,
                                         onThread: { _ in }, onDelta: { _ in }, onActivity: { _ in })
        }
        let requests = try fixture.requests()
        let starts = requests.filter { ["thread/start", "thread/resume"].contains($0["method"] as? String ?? "") }
        let turns = requests.filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(turns.count, 3)
        for (index, expected) in [("future-model", "future-effort"), ("configured-model", "low"), ("configured-model", "medium")].enumerated() {
            let start = try XCTUnwrap(starts[index]["params"] as? [String: Any])
            let turn = try XCTUnwrap(turns[index]["params"] as? [String: Any])
            XCTAssertEqual(start["model"] as? String, expected.0)
            XCTAssertEqual((start["config"] as? [String: Any])?["model_reasoning_effort"] as? String, expected.1)
            XCTAssertEqual(turn["model"] as? String, expected.0)
            XCTAssertEqual(turn["effort"] as? String, expected.1)
        }
        XCTAssertEqual(requests.filter { $0["method"] as? String == "model/list" }.count, 1, "The catalog is cached per connection")
    }

    @MainActor
    func testChoosingANewModelUsesItsEffortDefaultAndRejectsUnsupportedEffortBeforeSubmission() async throws {
        let fixture = try FakeServer(mode: "stream")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        _ = try await client.respond(threadID: "thread-1", prompt: "继续", imageURL: nil, workspaceURL: fixture.workspace,
                                     model: "future-model", onThread: { _ in }, onDelta: { _ in }, onActivity: { _ in })
        let turns = try fixture.requests().filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual((turns.last?["params"] as? [String: Any])?["effort"] as? String, "future-effort")
        do {
            _ = try await client.respond(threadID: "thread-1", prompt: "不应提交", imageURL: nil, workspaceURL: fixture.workspace,
                                         model: "future-model", effort: "unsupported", onThread: { _ in }, onDelta: { _ in }, onActivity: { _ in })
            XCTFail("Unsupported effort must fail before a turn is submitted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不支持"))
        }
        XCTAssertEqual(try fixture.requests().filter { $0["method"] as? String == "turn/start" }.count, 1)
    }

    @MainActor
    func testCatalogDefaultResolvesWhenCLIHasNoExplicitModelAndBadPaginationFails() async throws {
        let fixture = try FakeServer(mode: "catalogDefault")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        _ = try await respond(client, fixture: fixture)
        let turn = try XCTUnwrap(try fixture.requests().first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual(turn["model"] as? String, "configured-model")
        XCTAssertEqual(turn["effort"] as? String, "low", "Catalog default is used without a CLI config override")
        for mode in ["catalogLoop", "catalogMalformed", "catalogCursorMalformed"] {
            let bad = try FakeServer(mode: mode)
            defer { bad.remove() }
            let broken = CodexClient(executableOverride: bad.executable.path, requestTimeout: 2, turnTimeout: 3)
            defer { broken.shutdown() }
            do {
                _ = try await broken.listModels(workspaceURL: bad.workspace)
                XCTFail("\(mode) must fail")
            } catch {
                guard case .protocolFailure = error as? CodexBridgeError else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertFalse(broken.isRunning)
        }
    }

    @MainActor
    func testInvalidConfiguredEffortFallsBackToTheModelsAdvertisedDefault() async throws {
        let fixture = try FakeServer(mode: "unsupportedConfigEffort")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        _ = try await respond(client, fixture: fixture)
        let turn = try XCTUnwrap(try fixture.requests().first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual(client.configuredEffort, "unsupported")
        XCTAssertEqual(turn["effort"] as? String, "low")
    }

    @MainActor
    func testFakeProcessMultipleImagesPreserveOrderAndLegacyImageDeduplicationOnResume() async throws {
        let fixture = try FakeServer(mode: "stream")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        let firstImage = fixture.workspace.appendingPathComponent("图表 A.png")
        let secondImage = fixture.workspace.appendingPathComponent("图表 B.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0D8AAAAASUVORK5CYII="))
        try png.write(to: firstImage)
        try png.write(to: secondImage)
        let aliases = fixture.workspace.appendingPathComponent("figures", isDirectory: true)
        try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: false)
        let firstAlias = aliases.appendingPathComponent("../图表 A.png")
        let secondAlias = aliases.appendingPathComponent("../图表 B.png")
        var threads: [String] = []
        var streamed = ""

        let first = try await client.respond(threadID: nil, prompt: "比较两张图表", imageURL: nil,
                                             imageURLs: [firstImage, secondImage], workspaceURL: fixture.workspace,
                                             onThread: { threads.append($0) }, onDelta: { streamed += $0 }, onActivity: { _ in })
        XCTAssertEqual(first, "你好，世界")
        XCTAssertEqual(streamed, first)
        let persistedThread = try XCTUnwrap(threads.first)
        let second = try await client.respond(threadID: persistedThread, prompt: "保留图表顺序继续比较", imageURL: firstAlias,
                                              imageURLs: [firstImage, secondImage, secondAlias], workspaceURL: fixture.workspace,
                                              onThread: { threads.append($0) }, onDelta: { _ in }, onActivity: { _ in })
        XCTAssertEqual(second, first)
        XCTAssertEqual(threads, ["thread-1", "thread-1"])
        XCTAssertFalse(client.isRunning)

        let requests = try fixture.requests()
        XCTAssertEqual(requests.filter { $0["method"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        let resumed = try XCTUnwrap(requests.first { $0["method"] as? String == "thread/resume" }?["params"] as? [String: Any])
        XCTAssertEqual(resumed["threadId"] as? String, persistedThread)
        let turns = requests.filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(turns.count, 2)
        for turn in turns {
            let params = try XCTUnwrap(turn["params"] as? [String: Any])
            XCTAssertEqual(params["threadId"] as? String, persistedThread)
            let input = try XCTUnwrap(params["input"] as? [[String: Any]])
            XCTAssertEqual(input.map { $0["type"] as? String }, ["text", "localImage", "localImage"])
            XCTAssertEqual(input.compactMap { $0["path"] as? String },
                           [firstImage.standardizedFileURL.path, secondImage.standardizedFileURL.path],
                           "Both distinct images must survive, in order; aliases and the legacy argument must not duplicate them")
        }
    }

    @MainActor
    func testFakeProcessCommentaryIsActivityOnlyAndExcludedFromCompletedAnswer() async throws {
        for mode in ["phases", "phasesFallback", "phasesLate"] {
            let fixture = try FakeServer(mode: mode)
            defer { fixture.remove() }
            let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
            defer { client.shutdown() }
            var streamed = ""
            var activities: [String] = []
            let answer = try await client.respond(threadID: nil, prompt: "解释术语", imageURL: nil,
                                                  workspaceURL: fixture.workspace, onThread: { _ in },
                                                  onDelta: { streamed += $0 }, onActivity: { activities.append($0) })
            XCTAssertEqual(answer, "术语定义：样本外验证。", "\(mode) must return only answer-phase text")
            XCTAssertFalse(answer.contains("我会先"))
            XCTAssertTrue(activities.contains(where: { $0.contains("我会先核对原文") }))
            if mode != "phasesLate" {
                XCTAssertEqual(streamed, answer, "Explicit started/fallback commentary must not enter the streaming answer either")
            }
            // When phase is first disclosed at completion, the append-only
            // preview cannot retract old bytes; the final returned value corrects it.
            XCTAssertFalse(client.isRunning)
        }
    }

    @MainActor
    func testFakeProcessUnknownPhaseRetainsLegacyStreamingBehavior() async throws {
        let fixture = try FakeServer(mode: "phasesUnknown")
        defer { fixture.remove() }
        let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
        defer { client.shutdown() }
        var streamed = ""
        let answer = try await client.respond(threadID: nil, prompt: "兼容旧服务", imageURL: nil,
                                              workspaceURL: fixture.workspace, onThread: { _ in },
                                              onDelta: { streamed += $0 }, onActivity: { _ in })
        XCTAssertEqual(answer, "兼容答案")
        XCTAssertEqual(streamed, answer)
    }

    @MainActor
    func testFakeProcessResumeReplayCannotClaimNewTurnAndEarlyEventsAreReplayed() async throws {
        for mode in ["resumeReplay", "earlyTurnEvents"] {
            let fixture = try FakeServer(mode: mode)
            defer { fixture.remove() }
            let client = CodexClient(executableOverride: fixture.executable.path, requestTimeout: 2, turnTimeout: 3)
            defer { client.shutdown() }
            var thread: String?
            var firstStream = ""
            let first = try await client.respond(threadID: nil, prompt: "第一轮", imageURL: nil,
                                                 workspaceURL: fixture.workspace, onThread: { thread = $0 },
                                                 onDelta: { firstStream += $0 }, onActivity: { _ in })
            var secondStream = ""
            let second = try await client.respond(threadID: thread, prompt: "恢复后第二轮", imageURL: nil,
                                                  workspaceURL: fixture.workspace, onThread: { _ in },
                                                  onDelta: { secondStream += $0 }, onActivity: { _ in })
            XCTAssertEqual(first, "本轮回答-1，完整。", mode)
            XCTAssertEqual(second, "本轮回答-2，完整。", mode)
            XCTAssertEqual(firstStream, first, "Early first-turn events must not be dropped")
            XCTAssertEqual(secondStream, second, "Only this RPC's actual turn may contribute text")
            XCTAssertFalse(secondStream.contains("旧回放"))
            XCTAssertFalse(client.isRunning)
            let requests = try fixture.requests()
            XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 2)
            XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/resume" }.count, 1)
        }
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
        turn_count=0
        def emit(value):
            payload=(json.dumps(value,ensure_ascii=False)+'\\n').encode('utf-8')
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.flush()
        def reply(req,value): emit({'id':req['id'],'result':value})
        def note(method,params): emit({'method':method,'params':params})
        def replay_old(turn_id,item_id):
            note('turn/started',{'threadId':'thread-1','turn':{'id':turn_id,'status':'inProgress','items':[]}})
            note('item/started',{'threadId':'thread-1','turnId':turn_id,'item':{'type':'agentMessage','id':item_id,'text':'','phase':'commentary'}})
            note('item/agentMessage/delta',{'threadId':'thread-1','turnId':turn_id,'itemId':item_id,'delta':'旧回放不能进入答案'})
            note('error',{'threadId':'thread-1','turnId':turn_id,'willRetry':False,'error':{'message':'旧回放错误'}})
            note('turn/completed',{'threadId':'thread-1','turn':{'id':turn_id,'status':'failed','items':[],'error':{'message':'旧回放失败'}}})
        for line in sys.stdin:
            req=json.loads(line)
            with open(logfile,'a') as f: f.write(json.dumps(req)+'\\n')
            method=req.get('method')
            if method=='initialize':
                if mode=='initializeTimeout': continue
                reply(req,{'userAgent':'fake'})
            elif method=='config/read':
                config={'mcp_servers':{'unsafe':{'command':'not-run','enabled':True}}}
                if mode!='catalogDefault': config.update(model='configured-model',model_reasoning_effort='medium')
                if mode=='unsupportedConfigEffort': config['model_reasoning_effort']='unsupported'
                reply(req,{'config':config})
            elif method=='model/list':
                first={'id':'configured-id','model':'configured-model','displayName':'Configured Model','description':'Default CLI model','isDefault':True,'hidden':False,'defaultReasoningEffort':'low','supportedReasoningEfforts':[{'reasoningEffort':'low','description':'Fast'},{'reasoningEffort':'medium','description':'Balanced'}]}
                future={'id':'future-id','model':'future-model','displayName':'Future Model','description':'Forward compatibility','isDefault':False,'hidden':False,'defaultReasoningEffort':'future-effort','supportedReasoningEfforts':[{'reasoningEffort':'future-effort','description':'New effort'}],'inputModalities':['text','future-modality'],'futureMetadata':{'new':True}}
                hidden=dict(future,id='hidden-id',model='hidden-model',hidden=True)
                if mode=='catalogMalformed': first['model']=''
                if mode=='catalog':
                    reply(req,{'data':[first] if not req['params'].get('cursor') else [first,future,hidden],'nextCursor':'next-page' if not req['params'].get('cursor') else None})
                else:
                    reply(req,{'data':[first,future],'nextCursor':'same-page' if mode=='catalogLoop' else (42 if mode=='catalogCursorMalformed' else None)})
            elif method in ['thread/start','thread/resume']:
                reply(req,{'thread':{'id':'thread-1'},'sandbox':{'type':'dangerFullAccess' if mode=='unsafePolicy' else 'readOnly'},'approvalPolicy':'never'})
            elif method=='mcpServerStatus/list':
                if mode in ['resumeReplay','earlyTurnEvents'] and turn_count>0:
                    replay_old('turn-'+str(turn_count),'answer-'+str(turn_count+1))
                reply(req,{'data':[{'name':'unsafe','runtimeStatus':'ready' if mode=='unsafeMCP' else 'disabled','tools':{'bad':{}} if mode=='unsafeMCP' else {}}],'nextCursor':None})
            elif method=='turn/start':
                if mode in ['resumeReplay','earlyTurnEvents']:
                    turn_count+=1
                    turn_id='turn-'+str(turn_count)
                    item_id='answer-'+str(turn_count)
                    answer={'type':'agentMessage','id':item_id,'text':'本轮回答-'+str(turn_count)+'，完整。','phase':'final_answer'}
                    if mode=='resumeReplay':
                        reply(req,{'turn':{'id':turn_id,'status':'inProgress','items':[]}})
                        time.sleep(0.025)
                    replay_old('stale-turn',item_id)
                    note('turn/started',{'threadId':'thread-1','turn':{'id':turn_id,'status':'inProgress','items':[]}})
                    note('item/started',{'threadId':'thread-1','turnId':turn_id,'item':dict(answer,text='')})
                    note('item/agentMessage/delta',{'threadId':'thread-1','turnId':turn_id,'itemId':item_id,'delta':'本轮回答-'+str(turn_count)})
                    replay_old('another-stale-turn','unrelated-old-item')
                    note('item/completed',{'threadId':'thread-1','turnId':turn_id,'item':answer})
                    note('turn/completed',{'threadId':'thread-1','turn':{'id':turn_id,'status':'completed','items':[answer]}})
                    if mode=='earlyTurnEvents':
                        reply(req,{'turn':{'id':turn_id,'status':'inProgress','items':[]}})
                    continue
                reply(req,{'turn':{'id':'turn-1','status':'inProgress','items':[]}})
                if mode=='processExit': sys.exit(9)
                if mode=='turnTimeout': continue
                if mode=='approval':
                    emit({'id':'approve-1','method':'item/fileChange/requestApproval','params':{'threadId':'thread-1','turnId':'turn-1'}})
                    continue
                if mode in ['phases','phasesFallback','phasesLate']:
                    progress={'type':'agentMessage','id':'progress-1','text':'我会先核对原文，再给出释义。','phase':'commentary'}
                    answer={'type':'agentMessage','id':'answer-1','text':'术语定义：样本外验证。','phase':'final_answer'}
                    if mode!='phasesFallback':
                        if mode=='phases':
                            note('item/started',{'threadId':'thread-1','turnId':'turn-1','item':dict(progress,text='')})
                        note('item/agentMessage/delta',{'threadId':'thread-1','turnId':'turn-1','itemId':'progress-1','delta':'我会先核对原文'})
                        note('item/completed',{'threadId':'thread-1','turnId':'turn-1','item':dict(progress,phase=None) if mode=='phases' else progress})
                        note('item/started',{'threadId':'thread-1','turnId':'turn-1','item':dict(answer,text='')})
                        note('item/agentMessage/delta',{'threadId':'thread-1','turnId':'turn-1','itemId':'answer-1','delta':'术语定义：'})
                        note('item/completed',{'threadId':'thread-1','turnId':'turn-1','item':answer})
                    note('turn/completed',{'threadId':'thread-1','turn':{'id':'turn-1','status':'completed','items':[progress,answer]}})
                    continue
                if mode=='phasesUnknown':
                    note('item/started',{'threadId':'thread-1','turnId':'turn-1','item':{'type':'agentMessage','id':'answer-1','text':'','phase':'future_answer'}})
                    note('item/agentMessage/delta',{'threadId':'thread-1','turnId':'turn-1','itemId':'answer-1','delta':'兼容'})
                    answer={'type':'agentMessage','id':'answer-1','text':'兼容答案','phase':None}
                    note('item/completed',{'threadId':'thread-1','turnId':'turn-1','item':answer})
                    note('turn/completed',{'threadId':'thread-1','turn':{'id':'turn-1','status':'completed','items':[answer]}})
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
