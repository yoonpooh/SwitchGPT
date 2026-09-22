import XCTest
@testable import SwitchGPT

final class JevMediaHistoryTests: XCTestCase {
    private let visual: [String: Any] = ["role": "user", "content": [
        ["type": "input_text", "text": "Check this screenshot"],
        ["type": "input_image", "image_url": "https://example.invalid/fixture.png"]]]
    private func user(_ text: String) -> [String: Any] {
        ["role": "user", "content": [["type": "input_text", "text": text]]]
    }
    private func request(_ items: [[String: Any]], turn: String = "turn") throws -> RelayRequest {
        RelayRequest(method: "POST", target: "/backend-api/codex/responses",
                     headers: ["thread-id": "media-fixture", "x-codex-turn-metadata": "{\"turn_id\":\"\(turn)\"}"],
                     body: try JSONSerialization.data(withJSONObject: ["model": "gpt-6-astra",
                                                                         "reasoning": ["effort": "medium"],
                                                                         "input": items]))
    }
    private func router() -> IntelligentModelRouter {
        let value = IntelligentModelRouter(classifier: { _, _ in JevRoutingAnswer(preset: "luna_medium", confidence: 0.99) })
        value.update(enabled: true, apiKey: "fixture")
        return value
    }
    func testIndependentTextAfterHistoricalImageRoutes() async throws {
        let result = await router().route(try request([visual, user("Calculate 12 + 34. Return only the number.")]))
        XCTAssertEqual(result.decision?.reason, "routed")
        XCTAssertEqual(result.decision?.selectedModel, "gpt-6-astra")
    }
    func testCurrentImageAndVisualReferencesKeepBaseline() async throws {
        for items in [[visual], [visual, user("아까 화면 간격을 고쳐줘")], [visual, user("이거 왜 이래?")],
                      [visual, user("응 그렇게 해줘")], [visual, user("What about the spacing?")], [visual, user("Look at the previous screenshot")],
                      [visual, user("고쳐줘"), user("응 계속해")]] {
            let original = try request(items)
            let result = await router().route(original)
            XCTAssertEqual(result.decision?.reason, "unsupported_request")
            XCTAssertEqual(result.request.body, original.body)
        }
    }
    func testInjectedContextDoesNotEraseCurrentImage() async throws {
        let result = await router().route(try request([visual, user("# AGENTS.md instructions\ncontext")] ))
        XCTAssertEqual(result.decision?.reason, "unsupported_request")
    }
    func testToolContinuationReusesSelectedModelAfterHistoryImage() async throws {
        let engine = router()
        let items = [visual, user("Calculate 12 + 34. Return only the number.")]
        let initial = await engine.route(try request(items))
        let continued = await engine.route(try request(items + [["type": "function_call_output", "call_id": "fixture", "output": "46"]]))
        XCTAssertEqual(initial.decision?.reason, "routed")
        XCTAssertEqual(continued.decision?.reason, "continuation_reused")
        XCTAssertEqual(continued.decision?.selectedModel, initial.decision?.selectedModel)
    }

    func testPastToolOutputBeforeNewUserStartsFreshClassification() async throws {
        let calls = MediaCallCounter()
        let engine = IntelligentModelRouter(classifier: { input, _ in
            await calls.increment()
            XCTAssertEqual(input.latestUserText, "New turn after the old tool result")
            XCTAssertEqual(input.priorUserText, "Old turn")
            XCTAssertEqual(input.recentToolOutputs, ["old result"])
            return JevRoutingAnswer(model: nil, effort: "low", modelConfidence: nil,
                                    effortConfidence: 0.99, horizon: 1)
        })
        engine.update(enabled: true, apiKey: "fixture")
        let result = await engine.route(try request([
            user("Old turn"),
            ["type": "function_call_output", "call_id": "old", "output": "old result"],
            user("New turn after the old tool result")
        ], turn: "new-turn"))
        XCTAssertEqual(result.decision?.reason, "routed")
        XCTAssertEqual(result.decision?.selectedEffort, "low")
        let classificationCount = await calls.value
        XCTAssertEqual(classificationCount, 1)
    }

    func testSingleConfigurationUpdateReceivesSelectedEffort() async throws {
        let calls = MediaCallCounter()
        let engine = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(model: nil, effort: "low", modelConfidence: nil,
                                    effortConfidence: 1, horizon: 1)
        })
        engine.update(enabled: true, apiKey: "fixture")
        let original = try request([
            ["type": "configuration_update", "reasoning": ["effort": "high"]],
            user("Continue with the existing configuration")
        ], turn: "config-update")
        let result = await engine.route(original)
        XCTAssertEqual(result.decision?.reason, "routed")
        XCTAssertEqual(result.decision?.selectedEffort, "low")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.request.body) as? [String: Any])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual((input[0]["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let classificationCount = await calls.value
        XCTAssertEqual(classificationCount, 1)
    }

    func testAdjacentConfigurationUpdatesStillFailOpen() async throws {
        let calls = MediaCallCounter()
        let engine = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(model: nil, effort: "low", modelConfidence: nil,
                                    effortConfidence: 1, horizon: 1)
        })
        engine.update(enabled: true, apiKey: "fixture")
        let original = try request([
            ["type": "configuration_update", "reasoning": ["effort": "high"]],
            ["type": "configuration_update", "reasoning": ["effort": "max"]],
            user("Continue with the existing configuration")
        ], turn: "adjacent-config-updates")
        let result = await engine.route(original)
        XCTAssertEqual(result.request.body, original.body)
        XCTAssertEqual(result.decision?.reason, "unsupported_request")
        let classificationCount = await calls.value
        XCTAssertEqual(classificationCount, 0)
    }

    func testSuccessfulToolOutputReusesHorizon() async throws {
        let calls = MediaCallCounter()
        let engine = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(model: nil, effort: "high", modelConfidence: nil,
                                    effortConfidence: 0.99, horizon: 2)
        })
        engine.update(enabled: true, apiKey: "fixture")
        let items = [user("Run the checks"), ["type": "function_call_output", "output": "ran 10 tests: 0 failures, exit_code=0"]]
        let initial = await engine.route(try request([user("Run the checks")], turn: "success-output"))
        let continued = await engine.route(try request(items, turn: "success-output"))
        XCTAssertEqual(initial.decision?.reason, "routed")
        XCTAssertEqual(continued.decision?.reason, "continuation_reused")
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testRetainOriginalForcesSameTurnReclassification() async throws {
        let calls = MediaCallCounter()
        let engine = IntelligentModelRouter(classifier: { _, _ in
            let count = await calls.incrementAndReturn()
            return JevRoutingAnswer(model: nil, effort: count == 1 ? "high" : "low",
                                    modelConfidence: nil, effortConfidence: 0.99, horizon: 5)
        })
        engine.update(enabled: true, apiKey: "fixture")
        let original = try request([user("Retry after upstream rejection")], turn: "retain-original")
        _ = await engine.route(original)
        engine.retainOriginal(for: original)
        let retried = await engine.route(original)
        XCTAssertEqual(retried.decision?.selectedEffort, "low")
        let classificationCount = await calls.value
        XCTAssertEqual(classificationCount, 2)
    }
    func testNewUnknownAttachmentStillExcluded() async throws {
        let file: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": "Read the report"], ["type": "input_file", "file_id": "fixture"]]]
        let result = await router().route(try request([visual, file]))
        XCTAssertEqual(result.decision?.reason, "unsupported_request")
    }
}

private actor MediaCallCounter {
    private var count = 0
    func increment() { count += 1 }
    func incrementAndReturn() -> Int { count += 1; return count }
    var value: Int { count }
}
