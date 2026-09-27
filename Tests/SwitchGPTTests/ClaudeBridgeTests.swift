import XCTest
import Network
import zlib
@testable import SwitchGPT

final class ClaudeBridgeTests: XCTestCase {
    func testToolTableExposesOnlyCodexFunctionAndCustomTools() throws {
        let table = try ClaudeBridge.toolTable([
            ["type": "function", "name": "exec", "description": "Run", "parameters": ["type": "object", "properties": ["input": ["type": "string"]]]],
            ["type": "custom", "name": "apply_patch", "format": ["type": "grammar"]],
            ["type": "namespace", "name": "mcp__codex_apps__", "tools": [["type": "function", "name": "search", "parameters": [String: Any]()]]],
            ["type": "namespace", "name": "mcp__claude_events", "tools": [["type": "function", "name": "observe"]]],
            ["type": "web_search"]
        ] as [Any])
        XCTAssertEqual(table.count, 3)
        XCTAssertEqual(Set(table.values.map(\.name)), ["exec", "apply_patch", "search"])
        XCTAssertTrue(table.keys.allSatisfy { $0.hasPrefix("t_") && $0.count == 22 })
        let custom = try XCTUnwrap(table.values.first { $0.kind == "custom" })
        XCTAssertEqual((custom.mcp["inputSchema"] as? [String: Any])?["required"] as? [String], ["input"])
        let search = try XCTUnwrap(table.values.first { $0.name == "search" })
        XCTAssertEqual(search.namespace, "mcp__codex_apps__")
        XCTAssertEqual((search.mcp["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        // Aliases are stable, so a continued Claude process keeps calling the same tools.
        XCTAssertEqual(Set(try ClaudeBridge.toolTable([["type": "function", "name": "exec"]] as [Any]).keys).count, 1)
        XCTAssertEqual(try ClaudeBridge.toolTable([["type": "function", "name": "exec"]] as [Any]).keys.first,
                       table.first { $0.value.name == "exec" }?.key)
    }

    func testPermissionModeMirrorsTheLatestCodexSelection() {
        XCTAssertEqual(ClaudePermissionMode.mirroring([Self.askMode]), .manual)
        XCTAssertEqual(ClaudePermissionMode.mirroring([Self.autoMode]), .auto)
        XCTAssertEqual(ClaudePermissionMode.mirroring([Self.fullAccess]), .bypassPermissions)
        XCTAssertEqual(ClaudePermissionMode.mirroring([Self.fullAccess, Self.planMode]), .plan)
        // The latest selection wins, and leaving Plan mode returns to the permission picker's mode.
        XCTAssertEqual(ClaudePermissionMode.mirroring([Self.fullAccess, Self.planMode, Self.autoMode, Self.defaultMode]), .auto)
        XCTAssertEqual(ClaudePermissionMode.mirroring([]), .manual)
        // Only Codex's own developer instructions count, never a user quoting them.
        XCTAssertEqual(ClaudePermissionMode.mirroring([["role": "user", "content": Self.fullAccess["content"] ?? ""]]), .manual)
        // Within one text the last block wins, and markers outside a block are ignored.
        let merged = Self.developer(Self.text(Self.planMode) + Self.text(Self.defaultMode) + Self.text(Self.autoMode) + Self.text(Self.askMode))
        XCTAssertEqual(ClaudePermissionMode.mirroring([merged]), .manual)
        let quoted = Self.developer("Never write `sandbox_mode` is `danger-full-access` or # Plan Mode here.\n" + Self.text(Self.askMode)
                                    + "\n<collaboration_mode># Collaboration Mode: Default (e.g. # Plan Mode)</collaboration_mode>")
        XCTAssertEqual(ClaudePermissionMode.mirroring([Self.autoMode, quoted]), .manual)
    }

    func testPromptKeepsRolesImagesAndCompactedHistory() throws {
        let image = "data:image/png;base64," + Data("png".utf8).base64EncodedString()
        let data: [String: Any] = ["instructions": "Be brief", "input": [
            ["type": "compaction", "encrypted_content": ClaudeBridge.compactionPrefix + "earlier summary"],
            ["role": "user", "content": [["type": "input_text", "text": "look"], ["type": "input_image", "image_url": image]]]
        ] as [Any]]
        let content = ClaudeBridge.promptContent(data, compacting: false)
        XCTAssertEqual(content.count, 2)
        let envelope = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(envelope.hasPrefix("{\"instructions\":\"Be brief\",\"conversation\":"))
        XCTAssertTrue(envelope.contains("\"compaction_summary\""))
        XCTAssertTrue(envelope.contains("earlier summary"))
        XCTAssertTrue(envelope.contains("[Attached image 1]"))
        XCTAssertEqual((content[1]["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        // A remote image is never fetched, and it does not fail the whole request either.
        let remote = ClaudeBridge.promptContent(["input": [["role": "user", "content": [
            ["type": "input_image", "image_url": "https://example.com/a.png"]]]]], compacting: false)
        XCTAssertEqual(remote.count, 1)
        XCTAssertTrue((remote[0]["text"] as? String)?.contains("Image not forwarded") == true)

        let compacting = ClaudeBridge.promptContent(["instructions": "secret rules", "input": [
            ["role": "user", "content": "hello"], ["type": "compaction_trigger"]] as [Any]], compacting: true)
        let prompt = try XCTUnwrap(compacting.first?["text"] as? String)
        XCTAssertTrue(prompt.hasPrefix("Write the handoff summary"))
        XCTAssertFalse(prompt.contains("secret rules"))
        XCTAssertFalse(prompt.contains("compaction_trigger"))
        XCTAssertTrue(ClaudeBridge.decodeSummary(["encrypted_content": "opaque"]).contains("cannot be read"))
    }

    func testPromptNamesHostedToolsAndDropsUnreadableGPTState() throws {
        let data: [String: Any] = ["tools": [["type": "function", "name": "exec"], ["type": "web_search"], ["type": "tool_search"],
                                             ["type": "web_search"]] as [Any],
                                   "input": [["type": "reasoning", "summary": [["type": "summary_text", "text": "plan"]], "encrypted_content": "gAAAA-secret"],
                                             ["type": "compaction", "encrypted_content": "gAAAA-openai"]] as [Any]]
        XCTAssertEqual(ClaudeBridge.hostedTools(data["tools"]), ["tool_search", "web_search"])
        let envelope = try XCTUnwrap(ClaudeBridge.promptContent(data, compacting: false).first?["text"] as? String)
        // Web search is not missing: Claude Code's WebSearch stands in for it.
        XCTAssertTrue(ClaudeBridge.webSearch(data["tools"]))
        XCTAssertFalse(ClaudeBridge.webSearch([["type": "tool_search"]] as [Any]))
        XCTAssertTrue(envelope.hasSuffix(#","unavailable_hosted_tools":["tool_search"]}"#))
        XCTAssertTrue(envelope.contains("plan"))
        XCTAssertFalse(envelope.contains("gAAAA"))
        XCTAssertTrue(envelope.contains("tell the user"))
        let plain = try XCTUnwrap(ClaudeBridge.promptContent(["input": [Any]()], compacting: false).first?["text"] as? String)
        XCTAssertFalse(plain.contains("unavailable_hosted_tools"))
    }

    func testCatalogOverrideIsDetectedOnlyAtTopLevel() {
        XCTAssertEqual(RoutingConfiguration.topLevelKeys("# x = 1\nmodel = \"a\"\n\"model_catalog_json\" = \"/c.json\"\n[t]\nb = 2"),
                       ["model", "model_catalog_json"])
        XCTAssertFalse(RoutingConfiguration.topLevelKeys("[profiles.x]\nmodel_catalog_json = \"/c.json\"").contains("model_catalog_json"))
    }

    /// Claude Code 2.1.281's model list for a Max account.
    nonisolated(unsafe) static let options: [[String: Any]] = [
        ["value": "default", "resolvedModel": "claude-opus-5-5[1m]", "description": "Opus 5.5 with 1M context · Best for everyday, complex tasks",
         "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
        ["value": "opus[1m]", "resolvedModel": "claude-opus-5-5[1m]", "description": "Opus 5.5 with 1M context · Best for everyday, complex tasks",
         "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
        ["value": "claude-fable-5-1[1m]", "resolvedModel": "claude-fable-5-1", "description": "Fable 5.1 · Most capable",
         "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max", "ultracode"]],
        ["value": "sonnet", "resolvedModel": "claude-sonnet-5", "description": "Sonnet 5 · Efficient for routine tasks",
         "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high"]],
        ["value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001", "description": "Haiku 4.5 · Fastest for quick answers"],
        ["value": "custom", "resolvedModel": "not a claude model"]
    ]

    func testModelListIsPinnedToResolvedModelsWithCodexEfforts() {
        let models = Self.options.compactMap(ClaudeModel.init(option:))
        XCTAssertEqual(models.map(\.slug), ["claude-code-opus-5-5", "claude-code-opus-5-5", "claude-code-fable-5-1",
                                            "claude-code-sonnet-5", "claude-code-haiku-4-5"])
        XCTAssertEqual(models.map(\.name), ["Opus 5.5", "Opus 5.5", "Fable 5.1", "Sonnet 5", "Haiku 4.5"])
        // An alias is replaced by the model it resolves to, so a Claude Code update cannot swap the model behind a slug.
        XCTAssertEqual(models.map(\.cliModel), ["claude-opus-5-5[1m]", "claude-opus-5-5[1m]", "claude-fable-5-1[1m]",
                                                "claude-sonnet-5", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(models[2].efforts, ["low", "medium", "high", "xhigh", "max"]) // Codex does not know "ultracode".
        XCTAssertEqual(models[3].efforts, ["low", "medium", "high"])
        XCTAssertEqual(models[4].efforts, [])
        XCTAssertEqual(models.map(\.contextWindow), [967_000, 967_000, 967_000, 167_000, 167_000])
        XCTAssertEqual(models[0], ClaudeModel.fallback)
        XCTAssertEqual(ClaudeModel.name("opus-6"), "Opus 6")
        XCTAssertEqual(ClaudeModel(option: ["value": "claude-opus-6", "description": "Something new"])?.name, "Opus 6")
    }

    func testCatalogAddsEachClaudeModelOnceAfterAccountModels() throws {
        let claude = [ClaudeModel.fallback,
                      ClaudeModel(slug: "claude-code-haiku-4-5", name: "Haiku 4.5", cliModel: "claude-haiku-4-5-20251001", efforts: [],
                                  contextWindow: 167_000)]
        let body = Data(#"{"models":[{"slug":"gpt-6-astra","priority":3},{"slug":"gpt-6-luna","priority":7}],"etag":"x"}"#.utf8)
        let updated = try XCTUnwrap(ClaudeBridge.addingCatalogItems(to: body, models: claude))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(models.map { $0["slug"] as? String }, ["gpt-6-astra", "gpt-6-luna", "claude-code-opus-5-5", "claude-code-haiku-4-5"])
        XCTAssertEqual(models.map { $0["priority"] as? Int }, [3, 7, 8, 9])
        XCTAssertEqual(models[2]["display_name"] as? String, "Opus 5.5")
        XCTAssertEqual(models[2]["context_window"] as? Int, 967_000)
        XCTAssertEqual(models[2]["max_context_window"] as? Int, 967_000)
        XCTAssertEqual(models[2]["comp_hash"] as? String, "3000")
        XCTAssertEqual(models[2]["default_reasoning_level"] as? String, "high")
        XCTAssertEqual((models[2]["supported_reasoning_levels"] as? [[String: Any]])?.count, 5)
        XCTAssertTrue((models[2]["description"] as? String)?.contains("Opus 5.5") == true)
        XCTAssertEqual(models[3]["context_window"] as? Int, 167_000)
        XCTAssertEqual((models[3]["supported_reasoning_levels"] as? [[String: Any]])?.map { $0["effort"] as? String }, ["medium"])
        XCTAssertEqual(models[3]["default_reasoning_level"] as? String, "medium")
        XCTAssertEqual(object["etag"] as? String, "x")
        XCTAssertNil(ClaudeBridge.addingCatalogItems(to: updated, models: claude))
        XCTAssertNil(ClaudeBridge.addingCatalogItems(to: Data("not json".utf8), models: claude))
        // A changed Claude list changes the validator even when the upstream list did not change.
        XCTAssertNotEqual(ClaudeBridge.catalogETag("W/\"a\"", models: claude), ClaudeBridge.catalogETag("W/\"a\"", models: [.fallback]))
        XCTAssertTrue(ClaudeBridge.catalogETag("W/\"a\"", models: claude).hasPrefix("W/\"a-switchgpt-claude-"))
    }

    func testModelCatalogAsksClaudeCodeAgainOnlyAfterAnUpdate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let file = root.appendingPathComponent("claude-models.json")
        let calls = Counter()
        let sonnet = ClaudeModel(slug: "claude-code-sonnet-5", name: "Sonnet 5", cliModel: "claude-sonnet-5", efforts: ["high"], contextWindow: 967_000)
        let catalog = ClaudeModelCatalog(file: file, executable: { executable }, discover: { _ in calls.increment(); return [sonnet] })
        XCTAssertEqual(catalog.models, [.fallback])
        XCTAssertEqual(catalog.model(for: ClaudeModel.fallback.slug), .fallback)
        await catalog.refreshed()
        await catalog.refreshed()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(catalog.models, [sonnet])
        // Threads that already use Opus 5.5 keep working even when it is no longer listed.
        XCTAssertEqual(catalog.model(for: ClaudeModel.fallback.slug), .fallback)
        XCTAssertNil(catalog.model(for: "claude-code-gone"))
        // Persisted: the next launch lists the same models before asking again.
        let reopened = ClaudeModelCatalog(file: file, executable: { executable }, discover: { _ in calls.increment(); return [] })
        XCTAssertEqual(reopened.models, [sonnet])
        await reopened.refreshed()
        XCTAssertEqual(calls.value, 1)
        // An updated CLI is asked again; a failed query keeps the previous list.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: executable.path)
        let failing = ClaudeModelCatalog(file: file, executable: { executable },
                                         discover: { _ in calls.increment(); throw ClaudeFailure(status: 502, message: "x") })
        await failing.refreshed()
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(failing.models, [sonnet])
    }

    func testDiscoveryReadsModelsAndContextWithoutAModelCall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        let options = String(decoding: try JSONSerialization.data(withJSONObject: Self.options), as: UTF8.self)
        let script = """
        #!/usr/bin/python3
        import json, sys
        args = sys.argv[1:]
        with open('\(root.path)/args.jsonl', 'a') as f: f.write(json.dumps(args) + '\\n')
        request = json.loads(sys.stdin.readline())
        model = args[args.index('--model') + 1] if '--model' in args else None
        subtype = request['request']['subtype']
        if subtype == 'initialize': answer = {'models': json.loads(r'''\(options)''')}
        else: answer = {'maxTokens': 200000, 'autoCompactThreshold': 167000 if 'haiku' in model else 967000}
        print(json.dumps({'type': 'system', 'subtype': 'status'}))
        print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': request['request_id'], 'response': answer}}))
        """
        FileManager.default.createFile(atPath: executable.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let models = try ClaudeModelDiscovery.run(executable: executable)
        XCTAssertEqual(models.map(\.slug), ["claude-code-opus-5-5", "claude-code-fable-5-1", "claude-code-sonnet-5", "claude-code-haiku-4-5"])
        XCTAssertEqual(models.map(\.contextWindow), [967_000, 967_000, 967_000, 167_000])
        let launches = try String(contentsOf: root.appendingPathComponent("args.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        XCTAssertEqual(launches.count, 5)
        XCTAssertTrue(launches.allSatisfy { $0.contains("--restricted") && $0.contains("--strict-mcp-config") && !$0.contains("--mcp-config") })
    }

    func testCompressedOpusRequestsAreDecodedBeforeRouting() throws {
        func request(_ body: String, encoding: String? = nil) throws -> RelayRequest {
            try request(Data(body.utf8), encoding: encoding)
        }
        func request(_ body: Data, encoding: String? = nil) throws -> RelayRequest {
            var head = "POST /backend-api/codex/responses HTTP/1.1\r\nContent-Length: \(body.count)\r\n"
            if let encoding { head += "Content-Encoding: \(encoding)\r\n" }
            return try XCTUnwrap(RelayRequest.parse(Data((head + "\r\n").utf8) + body))
        }
        func claude(_ request: RelayRequest) throws -> RelayRequest? {
            if case .claude(let decoded) = try ClaudeBridge.route(request, claudeEnabled: true) { return decoded }
            return nil
        }
        let opus = Data(#"{"model":"claude-code-opus-5-5"}"#.utf8)
        XCTAssertEqual(try claude(try request(opus))?.body, opus)
        XCTAssertNil(try claude(try request(#"{"model":"gpt-6-astra","input":"claude-code-opus-5-5"}"#)))
        // Codex compresses large bodies; an Opus conversation must be decoded, never forwarded to OpenAI.
        for (encoding, bits) in [("gzip", Int32(31)), ("deflate", Int32(15))] {
            let decoded = try XCTUnwrap(try claude(try request(try deflated(opus, windowBits: bits), encoding: encoding)))
            XCTAssertEqual(decoded.body, opus)
            XCTAssertNil(decoded.headers["content-encoding"])
            // A GPT request with nothing to rewrite keeps its original compressed bytes.
            let gpt = try request(try deflated(Data(#"{"model":"gpt-6-astra","input":[]}"#.utf8), windowBits: bits), encoding: encoding)
            guard case .openAI(let forwarded) = try ClaudeBridge.route(gpt, claudeEnabled: true) else { return XCTFail("GPT request went to Claude") }
            XCTAssertEqual(forwarded.body, gpt.body)
            XCTAssertEqual(forwarded.headers["content-encoding"], encoding)
        }
        if ZstdLibrary.shared != nil, let compressed = try zstd(opus) {
            XCTAssertEqual(try claude(try request(compressed, encoding: "zstd"))?.body, opus)
        }
        // Unreadable while Claude is on: it may be Opus, so it is refused locally. Off, OpenAI receives it as before.
        XCTAssertThrowsError(try ClaudeBridge.route(try request(opus, encoding: "br"), claudeEnabled: true)) { error in
            XCTAssertEqual((error as? ClaudeFailure)?.status, 415)
        }
        guard case .openAI = try ClaudeBridge.route(try request(opus, encoding: "br"), claudeEnabled: false) else { return XCTFail("Not forwarded") }
        XCTAssertThrowsError(try ClaudeBridge.route(try request(Data("not gzip".utf8), encoding: "gzip"), claudeEnabled: true))
    }

    /// Each case was rejected by the real OpenAI endpoint with a Claude-made item and accepted after this rewrite.
    func testGPTRequestsDropOnlyWhatOpenAIRejectsFromOpusHistory() throws {
        let input: [Any] = [
            ["type": "function_call", "id": "item_1", "call_id": "codex_claude_1", "name": "exec", "arguments": "{}"],
            ["type": "custom_tool_call", "id": "item_2", "call_id": "codex_claude_2", "name": "exec", "input": "x"],
            ["type": "function_call", "id": "fc_3", "call_id": "call_3", "name": "exec", "arguments": "{}"],
            ["type": "custom_tool_call", "id": "ctc_4", "call_id": "call_4", "name": "exec", "input": "x"],
            ["type": "reasoning", "id": "rs_claude", "summary": [["type": "summary_text", "text": "thinking"]]],
            ["type": "reasoning", "id": "rs_gpt", "summary": [Any](), "encrypted_content": "gAAAA"],
            ["type": "compaction", "encrypted_content": ClaudeBridge.compactionPrefix + "earlier work"],
            ["type": "compaction", "encrypted_content": "gAAAA-openai"],
            ["type": "message", "role": "assistant", "id": "msg_claude", "content": [["type": "output_text", "text": "hi"]]],
            ["type": "web_search_call", "id": ClaudeBridge.searchPrefix + "1", "status": "completed", "action": ["type": "search", "query": "q"]],
            ["type": "web_search_call", "id": "ws_gpt", "status": "completed", "action": ["type": "search", "query": "q"]]
        ]
        let cleaned = try XCTUnwrap(ClaudeBridge.openAIInput(input)).map { try XCTUnwrap($0 as? [String: Any]) }
        XCTAssertEqual(cleaned.map { $0["id"] as? String }, [nil, nil, "fc_3", "ctc_4", "rs_gpt", nil, nil, "msg_claude", "ws_gpt"])
        XCTAssertEqual(Array(cleaned.prefix(4).map { $0["call_id"] as? String }), ["codex_claude_1", "codex_claude_2", "call_3", "call_4"])
        XCTAssertEqual(cleaned[5]["role"] as? String, "user")
        XCTAssertTrue(ClaudeBridge.text(cleaned[5]).contains("earlier work"))
        XCTAssertEqual(cleaned[6]["encrypted_content"] as? String, "gAAAA-openai")
        XCTAssertNil(ClaudeBridge.openAIInput(Array(input[2...3]) + [input[5], input[7], input[8], input[10]]))
    }

    func testClaudeCodeGetsWebSearchOnlyWhileCodexOffersIt() throws {
        let tools: [Any] = [["type": "function", "name": "exec"], ["type": "web_search"]]
        let table = try ClaudeBridge.toolTable(tools)
        let alias = try XCTUnwrap(table.keys.first)
        func arguments(_ data: [String: Any], table: [String: ClaudeTool], compacting: Bool = false) -> [String] {
            ClaudeRun(key: "k", turnID: nil, model: .fallback, data: data, inputs: [], table: table, compacting: compacting)
                .arguments(relay: URL(fileURLWithPath: "/usr/bin/true"), config: URL(fileURLWithPath: "/tmp/relay.json"))
        }
        func value(_ arguments: [String], _ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        let search = arguments(["tools": tools], table: table)
        XCTAssertEqual(value(search, "--tools"), "WebSearch")
        XCTAssertEqual(value(search, "--allowedTools"), "mcp__codex__" + alias + ",WebSearch")
        XCTAssertTrue(search.contains("--restricted"))
        let plain = arguments(["tools": [tools[0]]], table: table)
        XCTAssertEqual(value(plain, "--tools"), "")
        XCTAssertEqual(value(plain, "--allowedTools"), "mcp__codex__" + alias)
        let compaction = arguments(["tools": [Any]()], table: [:], compacting: true)
        XCTAssertEqual(value(compaction, "--tools"), "")
        XCTAssertNil(value(compaction, "--allowedTools"))

        // Codex's default cached mode still gets WebSearch; a domain filter WebSearch cannot enforce does not.
        let cached: [Any] = [["type": "web_search", "external_web_access": false]]
        XCTAssertEqual(value(arguments(["tools": cached], table: [:]), "--tools"), "WebSearch")
        let filtered: [Any] = [["type": "web_search", "filters": ["allowed_domains": ["swift.org"]]]]
        XCTAssertFalse(ClaudeBridge.webSearch(filtered))
        XCTAssertEqual(value(arguments(["tools": filtered], table: [:]), "--tools"), "")
        let envelope = try XCTUnwrap(ClaudeBridge.promptContent(["tools": filtered, "input": [Any]()], compacting: false).first?["text"] as? String)
        XCTAssertTrue(envelope.hasSuffix(#","unavailable_hosted_tools":["web_search"]}"#))
    }

    func testCatalogETagIsDistinctFromUpstream() {
        let weak = ClaudeBridge.catalogETag("W/\"abc\"", models: [.fallback])
        XCTAssertTrue(weak.hasPrefix("W/\"abc-switchgpt-claude-") && weak.hasSuffix("\""), weak)
        XCTAssertTrue(ClaudeBridge.catalogETag("abc", models: [.fallback]).hasPrefix("abc-switchgpt-claude-"))
        XCTAssertEqual(ClaudeBridge.catalogETag("abc", models: [.fallback]), ClaudeBridge.catalogETag("abc", models: [.fallback]))
    }

    func testPreferencesFromOlderVersionsKeepClaudeDisabled() throws {
        let old = try JSONDecoder().decode(RoutingPreferences.self, from: Data(#"{"automatic":false,"desktopVerified":true}"#.utf8))
        XCTAssertFalse(old.claudeEnabled)
        XCTAssertFalse(old.automatic)
        var updated = old
        updated.claudeEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(updated)).claudeEnabled)
    }

    func testMCPRelayAnswersHandshakeLocally() throws {
        let config = Data(#"{"run_id":"r","token":"t","url":"http://127.0.0.1:9/relay"}"#.utf8)
        let relay = try XCTUnwrap(ClaudeMCPRelay(config: config, session: URLSession(configuration: .ephemeral)))
        let initialize = relay.reply(id: 1, method: "initialize", params: ["protocolVersion": "2025-06-18"])
        XCTAssertEqual((initialize["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil(relay.reply(id: 2, method: "ping", params: [:])["result"])
        XCTAssertEqual((relay.reply(id: 3, method: "resources/list", params: [:])["error"] as? [String: Any])?["code"] as? Int, -32601)
        // An unreachable SwitchGPT becomes a tool error, never a fabricated result.
        let call = relay.reply(id: 4, method: "tools/call", params: ["name": "x"])
        XCTAssertEqual((call["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNil(ClaudeMCPRelay(config: Data("{}".utf8), session: .shared))
    }

    func testClaudeCLIIsFoundInUserInstallLocation() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(ClaudeCLI.locate(home: home), executable)
    }

    // MARK: Relay integration

    @MainActor func testOpusToolCallPausesForCodexAndResumesTheSameClaudeProcess() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]]
        var input: [Any] = [harness.environment, ["role": "user", "content": [["type": "input_text", "text": "run it"]]]]
        let first = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "thread-1",
                                            "reasoning": ["effort": "xhigh"]])
        XCTAssertEqual(first.status, 200)
        let call = try XCTUnwrap(first.completed?["output"] as? [[String: Any]]).first { $0["type"] as? String == "function_call" }
        let callID = try XCTUnwrap(call?["call_id"] as? String)
        XCTAssertTrue(callID.hasPrefix(ClaudeBridge.callPrefix))
        XCTAssertEqual(call?["name"] as? String, "exec_command")
        XCTAssertTrue((call?["id"] as? String)?.hasPrefix("fc_") == true)
        XCTAssertEqual(call?["arguments"] as? String, #"{"cmd":"echo 42"}"#)
        XCTAssertEqual((first.completed?["usage"] as? [String: Any])?["input_tokens"] as? Int, 15)

        input += [try XCTUnwrap(call), ["type": "function_call_output", "call_id": callID, "output": "42"]]
        let second = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "thread-1",
                                             "reasoning": ["effort": "xhigh"]])
        XCTAssertEqual(second.status, 200)
        let message = try XCTUnwrap((second.completed?["output"] as? [[String: Any]])?.last)
        XCTAssertEqual(message["phase"] as? String, "final_answer")
        XCTAssertTrue(second.text.contains("result was 42"))
        let arguments = try harness.launches()
        XCTAssertEqual(arguments.count, 1) // The tool result went back to the running process.
        XCTAssertEqual(arguments[0].firstIndex(of: "--model").map { arguments[0][$0 + 1] }, "claude-opus-5-5[1m]")
        XCTAssertEqual(arguments[0].firstIndex(of: "--effort").map { arguments[0][$0 + 1] }, "xhigh")
        XCTAssertTrue(harness.upstream.requests.isEmpty)
    }

    @MainActor func testCompactionReturnsReadableSummaryItem() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "thread-2", "input": [
            harness.environment, ["role": "user", "content": "long history"], ["type": "compaction_trigger"]] as [Any]])
        XCTAssertEqual(response.status, 200)
        let item = try XCTUnwrap((response.completed?["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["type"] as? String, "compaction")
        XCTAssertEqual(item["encrypted_content"] as? String, ClaudeBridge.compactionPrefix + "Hello from Opus")
        XCTAssertEqual((response.completed?["usage"] as? [String: Any])?["input_tokens"] as? Int, 0)
    }

    @MainActor func testDisabledOrUnauthorizedOpusRequestsNeverReachClaude() async throws {
        let disabled = try await Harness(enabled: false)
        defer { disabled.stop() }
        let body: [String: Any] = ["model": ClaudeModel.fallback.slug, "prompt_cache_key": "t", "input": [disabled.environment]]
        for encoding in [nil, "gzip"] {
            // Turned off, Opus is refused locally: its conversation never reaches OpenAI.
            let refused = try await disabled.send(body, encoding: encoding)
            XCTAssertEqual(refused.status, 400)
            XCTAssertTrue(refused.text.contains(ClaudeBridge.disabledMessage))
        }
        XCTAssertTrue(disabled.upstream.requests.isEmpty)
        XCTAssertTrue(try disabled.launches().isEmpty)

        let enabled = try await Harness(enabled: true)
        defer { enabled.stop() }
        let rejected = try await enabled.send(body, token: "unknown")
        XCTAssertEqual(rejected.status, 401)
        let relay = try await enabled.post(ClaudeBridge.relayPath, body: ["run_id": "x", "method": "tools/list"], token: "desktop-token")
        XCTAssertEqual(relay, 401) // The MCP relay accepts only the executor's own token.
        XCTAssertTrue(try enabled.launches().isEmpty)
        XCTAssertTrue(enabled.upstream.requests.isEmpty)
    }

    @MainActor func testGzipOpusRequestRunsClaude() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "gz", "input": [
            harness.environment, ["role": "user", "content": "hello"]] as [Any]], encoding: "gzip")
        XCTAssertEqual(response.status, 200, response.text)
        XCTAssertTrue(response.text.contains("Hello from Opus"))
        XCTAssertEqual(try harness.launches().count, 1)
        XCTAssertTrue(harness.upstream.requests.isEmpty)
    }

    @MainActor func testGPTContinuationOfOpusThreadReachesOpenAIWithoutRejectedItems() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let input: [Any] = [["role": "user", "content": "hi"],
                            ["type": "custom_tool_call", "id": "item_1", "call_id": "codex_claude_1", "name": "exec", "input": "x"],
                            ["type": "custom_tool_call_output", "call_id": "codex_claude_1", "output": "1"],
                            ["type": "reasoning", "id": "rs_claude", "summary": [Any]()]]
        for encoding in [nil, "gzip"] {
            let response = try await harness.send(["model": "gpt-6-astra", "input": input], encoding: encoding)
            XCTAssertEqual(response.status, 200)
        }
        XCTAssertEqual(harness.upstream.requests.count, 2)
        for forwarded in harness.upstream.requests {
            XCTAssertNil(forwarded.headers["content-encoding"])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: forwarded.body) as? [String: Any])
            let items = try XCTUnwrap(body["input"] as? [[String: Any]])
            XCTAssertEqual(items.map { $0["type"] as? String }, [nil, "custom_tool_call", "custom_tool_call_output"])
            XCTAssertNil(items[1]["id"])
        }
        XCTAssertTrue(try harness.launches().isEmpty)
    }

    @MainActor func testClaudeThatNeverStartsFailsTheResponse() async throws {
        let harness = try await Harness(enabled: true, startLimit: 1)
        defer { harness.stop() }
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "start", "input": [
            harness.environment, ["role": "user", "content": "SLOW_START"]] as [Any]])
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.text.contains("response.failed"), response.text)
        XCTAssertTrue(response.text.contains("did not start within 1 seconds"))
        try await Harness.waitUntilGone(try harness.processes())
    }

    @MainActor func testTurningClaudeOffEndsWaitingRunAndRefusesItsContinuation() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]
        var input: [Any] = [harness.environment, ["role": "user", "content": "SPAWN_CHILD"]]
        let first = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "off"])
        let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" }, first.text)
        let pids = try harness.processes()
        XCTAssertEqual(pids.count, 2) // Claude and its child, standing in for the MCP relay.
        XCTAssertTrue(pids.allSatisfy(Harness.alive))

        harness.relay.claude.setEnabled(false)
        try await Harness.waitUntilGone(pids)
        input += [call, ["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String), "output": "42"]]
        let second = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "off"])
        XCTAssertEqual(second.status, 400)
        XCTAssertTrue(second.text.contains(ClaudeBridge.disabledMessage))
        XCTAssertEqual(try harness.launches().count, 1)
        XCTAssertTrue(harness.upstream.requests.isEmpty)
    }

    @MainActor func testEndedRunIsNeitherReplayedNorRefusedButContinuedFromHistory() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]
        var input: [Any] = [harness.environment, ["role": "user", "content": "run it"]]
        let body: [String: Any] = ["model": ClaudeModel.fallback.slug, "tools": tools, "prompt_cache_key": "ended"]
        var request = body
        request["input"] = input
        let first = try await harness.send(request)
        let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" }, first.text)
        harness.relay.claude.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Codex retries the same request: the ended run's tool call must not be handed out again.
        let retried = try await harness.send(request)
        XCTAssertEqual(retried.status, 200, retried.text)
        let retriedCall = try XCTUnwrap((retried.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" })
        XCTAssertNotEqual(retriedCall["call_id"] as? String, call["call_id"] as? String)
        harness.relay.claude.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        // A tool result for a run that no longer exists continues in a fresh process from the complete history.
        input += [call, ["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String), "output": "42"]]
        request["input"] = input
        let continued = try await harness.send(request)
        XCTAssertEqual(continued.status, 200, continued.text)
        XCTAssertNotNil(continued.completed, continued.text)
        XCTAssertEqual(try harness.launches().count, 3)
    }

    @MainActor func testNewChatWithoutProjectRunsClaudeOutsideTheCodexFolder() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        // No environment message and no prompt_cache_key: identity comes from Codex's turn metadata header.
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "", "input": [["role": "user", "content": "hello"]]],
                                              headers: ["x-codex-turn-metadata": #"{"thread_id":"new-chat","turn_id":"t1"}"#])
        XCTAssertEqual(response.status, 200, response.text)
        XCTAssertTrue(response.text.contains("Hello from Opus"))
        let cwd = try XCTUnwrap(try harness.workingDirectories().first)
        XCTAssertTrue(cwd.contains("switchgpt-claude-"), cwd)
        XCTAssertFalse(cwd.contains(harness.root.lastPathComponent))
        let anonymous = try await harness.send(["model": ClaudeModel.fallback.slug, "input": [["role": "user", "content": "hello"]]])
        XCTAssertEqual(anonymous.status, 400)
    }

    @MainActor func testClaudeWebSearchShowsAsCodexSearchCard() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let input: [Any] = [harness.environment, ["role": "user", "content": "SEARCH_WEB for the Swift release"]]
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "search", "input": input,
                                               "tools": [["type": "web_search"]]])
        XCTAssertEqual(response.status, 200, response.text)
        let output = try XCTUnwrap(response.completed?["output"] as? [[String: Any]])
        XCTAssertEqual(output.map { $0["type"] as? String }, ["web_search_call", "message"])
        XCTAssertTrue((output[0]["id"] as? String)?.hasPrefix(ClaudeBridge.searchPrefix) == true)
        XCTAssertEqual(output[0]["status"] as? String, "completed")
        XCTAssertEqual((output[0]["action"] as? [String: Any])?["query"] as? String, "swift release")
        XCTAssertEqual(output[1]["phase"] as? String, "final_answer")
        XCTAssertTrue(response.text.contains("Swift 6.4, per swift.org"))
        // The card appears while Claude Code is still searching.
        let added = response.text.components(separatedBy: "\n").compactMap { line -> [String: Any]? in
            guard line.hasPrefix("data: ") else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
        }.filter { $0["type"] as? String == "response.output_item.added" }.compactMap { $0["item"] as? [String: Any] }
        XCTAssertEqual(added.first?["type"] as? String, "web_search_call")
        XCTAssertEqual(added.first?["status"] as? String, "in_progress")

        // Without Codex web search, Claude Code gets no tool of its own.
        let plain = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "no-search", "input": input])
        XCTAssertEqual(plain.status, 200, plain.text)
        XCTAssertEqual((plain.completed?["output"] as? [[String: Any]])?.map { $0["type"] as? String }, ["message"])
        let launches = try harness.launches()
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches[0].firstIndex(of: "--tools").map { launches[0][$0 + 1] }, "WebSearch")
        XCTAssertEqual(launches[1].firstIndex(of: "--tools").map { launches[1][$0 + 1] }, "")
        XCTAssertFalse(launches[1].contains("--allowedTools"))
    }

    @MainActor func testSearchBesideCodexToolCallShowsOneFinishedCard() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]],
                            ["type": "web_search"]]
        var input: [Any] = [harness.environment, ["role": "user", "content": "SEARCH_WEB WITH_TOOL"]]
        func searches(_ response: (status: Int, text: String, completed: [String: Any]?)) -> [[String: Any]] {
            (response.completed?["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "web_search_call" }
        }
        // The tool call pauses the response while the search is still running; no card is left unfinished.
        let first = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "pause", "input": input, "tools": tools])
        XCTAssertEqual(first.status, 200, first.text)
        XCTAssertTrue(searches(first).isEmpty)
        XCTAssertFalse(first.text.contains("web_search_call"))
        let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" })
        input += [call, ["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String), "output": "42"]]
        // Its results arrive in the next response, which shows the finished search.
        let second = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "pause", "input": input, "tools": tools])
        XCTAssertEqual(second.status, 200, second.text)
        XCTAssertEqual(searches(second).map { $0["status"] as? String }, ["completed"])
        XCTAssertEqual((searches(second).first?["action"] as? [String: Any])?["query"] as? String, "swift release")
        XCTAssertEqual(try harness.launches().count, 1)

        let failed = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "fail", "tools": [["type": "web_search"]],
                                             "input": [harness.environment, ["role": "user", "content": "SEARCH_WEB SEARCH_FAILS"]]])
        XCTAssertEqual(failed.status, 200, failed.text)
        XCTAssertEqual(searches(failed).map { $0["status"] as? String }, ["failed"])
    }

    @MainActor func testClaudeThatExitsEarlyReportsItsError() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "exit", "input": [
            harness.environment, ["role": "user", "content": "EXIT_EARLY"]] as [Any]])
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.text.contains("response.failed"), response.text)
        XCTAssertTrue(response.text.contains("exited without a result: Not logged in"), response.text)
    }

    @MainActor func testStalledClaudeFailsTheOpenResponse() async throws {
        let harness = try await Harness(enabled: true, stallLimit: 1)
        defer { harness.stop() }
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "stall", "input": [
            harness.environment, ["role": "user", "content": "STALL_NOW"]] as [Any]])
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.text.contains("response.failed"), response.text)
        XCTAssertTrue(response.text.contains("stopped responding"))
        try await Harness.waitUntilGone(try harness.processes())
    }

    @MainActor func testChangedEffortRestartsClaudeWithTheNewEffort() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]
        var input: [Any] = [harness.environment, ["role": "user", "content": "run it"]]
        let first = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "effort",
                                            "reasoning": ["effort": "xhigh"]])
        let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" }, first.text)
        input += [call, ["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String), "output": "42"]]
        let second = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "effort",
                                             "reasoning": ["effort": "low"]])
        XCTAssertEqual(second.status, 200, second.text)
        let efforts = try harness.launches().map { arguments in arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] } }
        XCTAssertEqual(efforts, ["xhigh", "low"])
    }

    @MainActor func testClaudeRunsInTheCodexPermissionModeAndRestartsWhenItChanges() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]
        var input: [Any] = [Self.askMode, Self.planMode, harness.environment, ["role": "user", "content": "plan it"]]
        let first = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "mode"])
        let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" }, first.text)
        // Claude Code's plan mode runs only read-only tools; Codex keeps its own for exploring.
        XCTAssertEqual(try harness.listedTools().first?.first?["annotations"] as? [String: Bool], ["readOnlyHint": true])
        // Only the mode changes: no new user message.
        input += [call, ["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String), "output": "42"],
                  Self.fullAccess, Self.defaultMode]
        let second = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "mode"])
        XCTAssertEqual(second.status, 200, second.text)
        let launches = try harness.launches()
        XCTAssertEqual(launches.map { arguments in arguments.firstIndex(of: "--permission-mode").map { arguments[$0 + 1] } },
                       ["plan", "bypassPermissions"])
        // Claude Code refuses bypassPermissions in restricted mode.
        XCTAssertEqual(launches.map { $0.contains("--restricted") }, [true, false])
        let prompts = launches.map { arguments in arguments.firstIndex(of: "--append-system-prompt").map { arguments[$0 + 1] } ?? "" }
        XCTAssertEqual(prompts.map { $0.contains("mirrors Codex Plan mode") }, [true, false])
        XCTAssertNil(try harness.listedTools().last?.first?["annotations"])
    }

    @MainActor func testShutdownLeavesNoClaudeProcesses() async throws {
        let harness = try await Harness(enabled: true)
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]
        let first = try await harness.send(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "quit", "tools": tools, "input": [
            harness.environment, ["role": "user", "content": "SPAWN_CHILD"]] as [Any]])
        XCTAssertEqual(first.status, 200)
        let pids = try harness.processes()
        XCTAssertEqual(pids.count, 2)
        harness.relay.claude.shutdown()
        try await Harness.waitUntilGone(pids)
    }

    @MainActor func testEachClaudeModelRunsItsOwnCLIModelAndSwitchingRestartsClaude() async throws {
        let haiku = ClaudeModel(slug: "claude-code-haiku-4-5", name: "Haiku 4.5", cliModel: "claude-haiku-4-5-20251001", efforts: [],
                                contextWindow: 167_000)
        let harness = try await Harness(enabled: true, models: [.fallback, haiku])
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]
        var input: [Any] = [harness.environment, ["role": "user", "content": "run it"]]
        let first = try await harness.send(["model": haiku.slug, "input": input, "tools": tools, "prompt_cache_key": "switch",
                                            "reasoning": ["effort": "xhigh"]])
        XCTAssertEqual(first.status, 200, first.text)
        XCTAssertEqual(first.completed?["model"] as? String, haiku.slug)
        let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" }, first.text)
        input += [call, ["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String), "output": "42"]]
        // The user switched to Opus while Haiku waited for the tool result: a fresh process runs the complete history.
        let second = try await harness.send(["model": ClaudeModel.fallback.slug, "input": input, "tools": tools, "prompt_cache_key": "switch",
                                             "reasoning": ["effort": "high"]])
        XCTAssertEqual(second.status, 200, second.text)
        XCTAssertEqual(second.completed?["model"] as? String, ClaudeModel.fallback.slug)
        let launches = try harness.launches()
        XCTAssertEqual(launches.map { $0[$0.firstIndex(of: "--model")! + 1] }, ["claude-haiku-4-5-20251001", "claude-opus-5-5[1m]"])
        XCTAssertEqual(launches.map { args in args.firstIndex(of: "--effort").map { args[$0 + 1] } }, [nil, "high"])

        // A Claude model Claude Code no longer lists is refused locally, never sent to OpenAI.
        let gone = try await harness.send(["model": "claude-code-gone-1", "prompt_cache_key": "gone", "input": [harness.environment]])
        XCTAssertEqual(gone.status, 400)
        XCTAssertTrue(gone.text.contains(ClaudeBridge.unavailableMessage("claude-code-gone-1")))
        XCTAssertTrue(harness.upstream.requests.isEmpty)
    }

    @MainActor func testModelListIncludesOpusOnlyWhileEnabled() async throws {
        for enabled in [true, false] {
            let harness = try await Harness(enabled: enabled)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/backend-api/codex/models?client_version=1")!)
            request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")
            request.setValue("W/\"cached\"", forHTTPHeaderField: "If-None-Match")
            let (body, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let etag = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
            XCTAssertEqual(etag, enabled ? ClaudeBridge.catalogETag("W/\"catalog\"", models: [.fallback]) : "W/\"catalog\"")
            let models = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["models"] as? [[String: Any]])
            XCTAssertEqual(models.contains { $0["slug"] as? String == ClaudeModel.fallback.slug }, enabled)
            XCTAssertEqual(harness.upstream.requests.first?.headers["if-none-match"] == nil, enabled)
            harness.stop()
        }
    }

    @MainActor func testModelListWaitsForClaudeCodeToBeAskedAgain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let sonnet = ClaudeModel(slug: "claude-code-sonnet-5", name: "Sonnet 5", cliModel: "claude-sonnet-5", efforts: ["high"], contextWindow: 967_000)
        // Claude Code was just updated: the list ChatGPT fetches after its restart must already include the new models.
        let catalog = ClaudeModelCatalog(file: root.appendingPathComponent("claude-models.json"), executable: { executable },
                                         discover: { _ in Thread.sleep(forTimeInterval: 0.5); return [sonnet] })
        let harness = try await Harness(enabled: true, catalog: catalog)
        defer { harness.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/backend-api/codex/models?client_version=1")!)
        request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let models = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["slug"] as? String }.filter(ClaudeModel.isClaude), [sonnet.slug])
    }

    func testSlowModelQueryServesThePreviousListAfterTheWait() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let sonnet = ClaudeModel(slug: "claude-code-sonnet-5", name: "Sonnet 5", cliModel: "claude-sonnet-5", efforts: ["high"], contextWindow: 967_000)
        let catalog = ClaudeModelCatalog(executable: { executable }, discover: { _ in Thread.sleep(forTimeInterval: 1); return [sonnet] })
        let start = Date()
        // Resuming twice would trap: the completion runs once, at the deadline, even though the query finishes later.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            catalog.refresh(waitingAtMost: 0.1) { continuation.resume() }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
        XCTAssertEqual(catalog.models, [.fallback])
        await catalog.refreshed()
        XCTAssertEqual(catalog.models, [sonnet])
    }

    /// Opt-in: SWITCHGPT_LIVE_RELAY=<built SwitchGPT executable> runs the signed-in Claude Code CLI once per Codex permission mode.
    @MainActor func testLiveOpusCallsCodexToolThroughBuiltRelay() async throws {
        let relayPath = ProcessInfo.processInfo.environment["SWITCHGPT_LIVE_RELAY"] ?? ""
        try XCTSkipIf(relayPath.isEmpty, "Set SWITCHGPT_LIVE_RELAY to run against the real Claude Code CLI")
        let claude = try XCTUnwrap(ClaudeCLI.locate())
        // Records each launch, then runs the real CLI unchanged.
        let wrapperDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: wrapperDirectory) }
        let wrapper = wrapperDirectory.appendingPathComponent("claude")
        let script = "#!/usr/bin/python3\nimport json, os, sys\nwith open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'launches.jsonl'), 'a') as f: "
            + "f.write(json.dumps(sys.argv[1:]) + '\\n')\nos.execv(\(ClaudeBridge.text(claude.path)), [\(ClaudeBridge.text(claude.path))] + sys.argv[1:])\n"
        FileManager.default.createFile(atPath: wrapper.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let harness = try await Harness(enabled: true, claude: wrapper, relayExecutable: URL(fileURLWithPath: relayPath))
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "description": "Run a shell command",
                             "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]]]
        let modes: [(String, [Any])] = [("manual", [Self.askMode]), ("auto", [Self.autoMode]), ("bypassPermissions", [Self.fullAccess]),
                                        ("plan", [Self.askMode, Self.planMode])]
        for (mode, instructions) in modes {
            var input: [Any] = instructions + [harness.environment, ["role": "user", "content": [["type": "input_text",
                "text": "Call exec_command exactly once with cmd \"echo 42\". After the result arrives, reply with only the command output."]]]]
            let body: [String: Any] = ["model": ClaudeModel.fallback.slug, "tools": tools, "prompt_cache_key": "live-" + mode,
                                       "reasoning": ["effort": "low"], "instructions": "You are testing a tool relay."]
            var request = body
            request["input"] = input
            let first = try await harness.send(request)
            XCTAssertEqual(first.status, 200, first.text)
            let call = try XCTUnwrap((first.completed?["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" },
                                     mode + ": " + first.text)
            let callID = try XCTUnwrap(call["call_id"] as? String)
            input += [call, ["type": "function_call_output", "call_id": callID, "output": "42"]]
            request["input"] = input
            let second = try await harness.send(request)
            XCTAssertEqual(second.status, 200, second.text)
            let answer = try XCTUnwrap((second.completed?["output"] as? [[String: Any]])?.last)
            XCTAssertEqual(answer["phase"] as? String, "final_answer", mode)
            XCTAssertTrue(second.text.contains("42"), mode)
            let launches = try String(contentsOf: wrapperDirectory.appendingPathComponent("launches.jsonl"), encoding: .utf8)
            let launched = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(launches.split(separator: "\n").last).utf8))
            XCTAssertEqual(launched.firstIndex(of: "--permission-mode").map { launched[$0 + 1] }, mode)
        }
    }

    /// The real CLI must report exactly the relay tools plus WebSearch, and stream the search as a card.
    @MainActor func testLiveClaudeWebSearchBecomesSearchCard() async throws {
        let relayPath = ProcessInfo.processInfo.environment["SWITCHGPT_LIVE_RELAY"] ?? ""
        try XCTSkipIf(relayPath.isEmpty, "Set SWITCHGPT_LIVE_RELAY to run against the real Claude Code CLI")
        let claude = try XCTUnwrap(ClaudeCLI.locate())
        let harness = try await Harness(enabled: true, claude: claude, relayExecutable: URL(fileURLWithPath: relayPath))
        defer { harness.stop() }
        let tools: [Any] = [["type": "function", "name": "exec_command", "description": "Run a shell command",
                             "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]],
                            ["type": "web_search", "external_web_access": false]] // Codex's default cached mode.
        let input: [Any] = [harness.environment, ["role": "user", "content": [["type": "input_text",
            "text": "Search the web exactly once for the latest stable Swift release, then answer in one sentence with its source."]]]]
        let response = try await harness.send(["model": ClaudeModel.fallback.slug, "tools": tools, "prompt_cache_key": "live-search",
                                               "reasoning": ["effort": "low"], "input": input])
        XCTAssertEqual(response.status, 200, response.text)
        let output = try XCTUnwrap(response.completed?["output"] as? [[String: Any]], response.text)
        let search = try XCTUnwrap(output.first { $0["type"] as? String == "web_search_call" }, response.text)
        XCTAssertEqual(search["status"] as? String, "completed")
        XCTAssertFalse(((search["action"] as? [String: Any])?["query"] as? String ?? "").isEmpty)
        XCTAssertEqual(output.last?["phase"] as? String, "final_answer")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func deflated(_ data: Data, windowBits: Int32) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
                                     ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))))
        let status = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress
                stream.avail_in = uInt(source.count)
                stream.next_out = target.baseAddress
                stream.avail_out = uInt(target.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return Data(output.prefix(Int(stream.total_out)))
    }

    // Codex's permission picker and collaboration mode, as its developer instructions state them.
    private static func developer(_ text: String) -> [String: Any] {
        ["role": "developer", "content": [["type": "input_text", "text": text]]]
    }
    private static func text(_ message: [String: Any]) -> String {
        ((message["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }
    private static var askMode: [String: Any] {
        developer("<permissions instructions>\nFilesystem sandboxing defines which files can be read or written. `sandbox_mode` is "
                  + "`workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`.\n</permissions instructions>")
    }
    private static var autoMode: [String: Any] {
        developer("<permissions instructions>\n`sandbox_mode` is `workspace-write`.\n`approvals_reviewer` is `auto_review`: "
                  + "Sandbox escalations with require_escalated will be reviewed for compliance with the policy.\n</permissions instructions>")
    }
    private static var fullAccess: [String: Any] {
        developer("<permissions instructions>\nFilesystem sandboxing defines which files can be read or written. `sandbox_mode` is "
                  + "`danger-full-access`: No filesystem sandboxing - all commands are permitted.\nApproval policy is currently never.\n</permissions instructions>")
    }
    private static var planMode: [String: Any] {
        developer("<collaboration_mode># Plan Mode (Conversational)\n\nYou work in 3 phases.</collaboration_mode>")
    }
    private static var defaultMode: [String: Any] {
        developer("<collaboration_mode># Collaboration Mode: Default\n\nYou are now in Default mode. "
                  + "Any previous instructions for other modes (e.g. Plan mode) are no longer active.</collaboration_mode>")
    }

    /// Uses the zstd CLI when installed; nil skips the zstd case.
    private func zstd(_ data: Data) throws -> Data? {
        guard let tool = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first(where: FileManager.default.isExecutableFile) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-q", "-c"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? compressed : nil
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A relay wired to a fake Claude Code CLI that speaks stream-json and calls the MCP relay over HTTP.
@MainActor private final class Harness {
    let root: URL
    let upstream = CatalogServer()
    let relay: ModelRelay
    let port: UInt16
    var environment: [String: Any] {
        ["role": "user", "content": [["type": "input_text", "text": "<environment_context>\n  <cwd>\(root.path)</cwd>\n</environment_context>"]]]
    }

    init(enabled: Bool, claude: URL? = nil, relayExecutable: URL = URL(fileURLWithPath: "/usr/bin/true"),
         stallLimit: TimeInterval = 1200, startLimit: TimeInterval = 90, models: [ClaudeModel]? = nil,
         catalog: ClaudeModelCatalog? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fake = claude ?? root.appendingPathComponent("claude")
        if claude == nil {
            FileManager.default.createFile(atPath: fake.path, contents: Data(Self.fakeClaude.utf8), attributes: [.posixPermissions: 0o755])
        }
        let auth = root.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"desktop-token"}}"#.utf8).write(to: auth)
        let upstreamPort = try await upstream.start()
        let executor = ClaudeExecutor(claudeExecutable: { fake }, models: catalog ?? ClaudeModelCatalog(models: models),
                                      relayExecutable: relayExecutable, stallLimit: stallLimit, startLimit: startLimit)
        executor.setEnabled(enabled)
        relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!, claude: executor)
        let claims = Data(#"{"sub":"first-subject"}"#.utf8).base64EncodedString()
        relay.select(try RelayCredentials(Credential(data: Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"first-account","access_token":"first-token","refresh_token":"r","id_token":"h.\#(claims).s"}}"#.utf8))))
        port = try await relay.start(port: 0)
    }

    func stop() {
        relay.stop()
        upstream.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func launches() throws -> [[String]] {
        let file = root.appendingPathComponent("launches.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    /// Directories the fake Claude was started in.
    func workingDirectories() throws -> [String] {
        let file = root.appendingPathComponent("cwds.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
    }

    /// The Codex tools each fake Claude received from the relay.
    func listedTools() throws -> [[[String: Any]]] {
        let file = root.appendingPathComponent("tools.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]]) }
    }

    /// Process IDs the fake Claude reported: its own and any child it started.
    func processes() throws -> [pid_t] {
        let file = root.appendingPathComponent("pids.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").flatMap { try JSONDecoder().decode([pid_t].self, from: Data($0.utf8)) }
    }

    nonisolated static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    static func waitUntilGone(_ pids: [pid_t], timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while pids.contains(where: alive), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(pids.contains(where: alive), "Claude processes outlived their run: \(pids.filter(alive))")
    }

    func send(_ body: [String: Any], token: String = "desktop-token", encoding: String? = nil, headers: [String: String] = [:]) async throws
        -> (status: Int, text: String, completed: [String: Any]?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        let json = try JSONSerialization.data(withJSONObject: body)
        if let encoding {
            let gzip = Process()
            gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            gzip.arguments = ["-c"]
            let input = Pipe(), output = Pipe()
            gzip.standardInput = input
            gzip.standardOutput = output
            try gzip.run()
            try input.fileHandleForWriting.write(contentsOf: json)
            try input.fileHandleForWriting.close()
            request.httpBody = output.fileHandleForReading.readDataToEndOfFile()
            gzip.waitUntilExit()
            request.setValue(encoding, forHTTPHeaderField: "Content-Encoding")
        } else { request.httpBody = json }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        let completed = text.components(separatedBy: "\n").compactMap { line -> [String: Any]? in
            guard line.hasPrefix("data: "), let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  event["type"] as? String == "response.completed" else { return nil }
            return event["response"] as? [String: Any]
        }.last
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, text, completed)
    }

    func post(_ path: String, body: [String: Any], token: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static let fakeClaude = #"""
    #!/usr/bin/python3
    import json, os, subprocess, sys, time, urllib.request
    args = sys.argv[1:]
    home = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(home, 'launches.jsonl'), 'a') as f: f.write(json.dumps(args) + '\n')
    with open(os.path.join(home, 'cwds.jsonl'), 'a') as f: f.write(json.dumps(os.getcwd()) + '\n')
    def out(o): print(json.dumps(o), flush=True)
    prompt = sys.stdin.readline()
    json.loads(prompt)
    pids = [os.getpid()]
    if 'SPAWN_CHILD' in prompt: pids.append(subprocess.Popen(['/bin/sleep', '300']).pid)
    with open(os.path.join(home, 'pids.jsonl'), 'a') as f: f.write(json.dumps(pids) + '\n')
    if 'SLOW_START' in prompt: time.sleep(300)
    if 'EXIT_EARLY' in prompt:
        print('Not logged in', file=sys.stderr, flush=True)
        time.sleep(0.3)
        sys.exit(1)
    tools, conf = [], None
    if '--mcp-config' in args:
        conf = json.load(open(json.loads(args[args.index('--mcp-config') + 1])['mcpServers']['codex']['args'][1]))
    def call(method, params):
        body = json.dumps({'run_id': conf['run_id'], 'method': method, 'params': params}).encode()
        request = urllib.request.Request(conf['url'], data=body, headers={'Authorization': 'Bearer ' + conf['token'], 'Content-Type': 'application/json'})
        return json.load(urllib.request.urlopen(request, timeout=30))
    if conf:
        listed = call('tools/list', {})['tools']
        with open(os.path.join(home, 'tools.jsonl'), 'a') as f: f.write(json.dumps(listed) + '\n')
        tools = [t['name'] for t in listed]
    search = '--tools' in args and 'WebSearch' in args[args.index('--tools') + 1]
    out({'type': 'system', 'subtype': 'init', 'tools': ['mcp__codex__' + t for t in tools] + (['WebSearch'] if search else [])})
    if 'STALL_NOW' in prompt: time.sleep(300)
    out({'type': 'stream_event', 'event': {'type': 'message_start', 'message': {'usage': {'input_tokens': 10, 'cache_read_input_tokens': 5, 'output_tokens': 1}}}})
    answer = 'Hello from Opus'
    if search and 'SEARCH_WEB' in prompt:
        out({'type': 'stream_event', 'event': {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'toolu_search', 'name': 'WebSearch', 'input': {}}}})
        for part in ['{"query": "swift', ' release"}']:
            out({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': part}}})
        out({'type': 'stream_event', 'event': {'type': 'content_block_stop', 'index': 0}})
        if tools and 'WITH_TOOL' in prompt:
            # A Codex tool call runs beside the search and reaches Codex before the search results.
            out({'type': 'stream_event', 'event': {'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'tool_use', 'id': 'toolu_mcp', 'name': 'mcp__codex__' + tools[0], 'input': {}}}})
            out({'type': 'stream_event', 'event': {'type': 'message_stop'}})
            call('tools/call', {'name': tools[0], 'arguments': {'cmd': 'echo 42'}})
            tools = []
        else:
            out({'type': 'stream_event', 'event': {'type': 'message_stop'}})
        failed = 'SEARCH_FAILS' in prompt
        out({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_search', 'content': 'Links: swift.org', 'is_error': failed}]}})
        answer = 'The search failed' if failed else 'Swift 6.4, per swift.org'
    if tools:
        out({'type': 'stream_event', 'event': {'type': 'content_block_start', 'content_block': {'type': 'tool_use'}}})
        answer = 'result was ' + call('tools/call', {'name': tools[0], 'arguments': {'cmd': 'echo 42'}})['content'][0]['text']
    out({'type': 'stream_event', 'event': {'type': 'content_block_start', 'content_block': {'type': 'text'}}})
    out({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': answer}}})
    out({'type': 'result', 'is_error': False, 'result': answer})
    sys.stdin.read()
    """#
}

/// Answers /models with a small catalog and every other request with a completed SSE stream.
private final class CatalogServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "switchgpt.test.catalog")
    private let lock = NSLock()
    private var captured: [RelayRequest] = []
    private var listener: NWListener?
    var requests: [RelayRequest] { lock.withLock { captured } }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    private func read(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
            var all = previous
            if let data { all.append(data) }
            guard let request = try? RelayRequest.parse(all) else { read(connection, previous: all); return }
            lock.withLock { captured.append(request) }
            let catalog = request.path.hasSuffix("/models")
            let body = catalog ? #"{"models":[{"slug":"gpt-6-astra","priority":1}]}"#
                : "data: {\"type\":\"response.completed\",\"response\":{}}\n\n"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(catalog ? "application/json" : "text/event-stream")\r\nETag: W/\"catalog\"\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
