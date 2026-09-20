import XCTest
@testable import SwitchGPT

final class IntelligentModelRouterTests: XCTestCase {
    func testDisabledRouterReturnsExactBodyWithoutCallingClassifier() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_max", confidence: 1)
        })
        let request = try makeRequest(body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": "Keep this exact body", "extra": ["nested": true]
        ])

        let result = await router.route(request)

        XCTAssertEqual(result.request.body, request.body)
        XCTAssertEqual(result.decision?.reason, ModelRoutingReason.disabled.rawValue)
        XCTAssertFalse(result.decision?.changed ?? true)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testAllFixedPresetsUseExpectedModelAndEffort() async throws {
        let expected: [(String, String, String)] = [
            ("luna_medium", "gpt-5.6-luna", "medium"),
            ("luna_max", "gpt-5.6-luna", "max"),
            ("sol_medium", "gpt-5.6-sol", "medium"),
            ("sol_high", "gpt-5.6-sol", "high"),
            ("astra_medium", "gpt-6-astra", "medium"),
            ("astra_high", "gpt-6-astra", "high")
        ]

        for (preset, model, effort) in expected {
            let router = IntelligentModelRouter(classifier: { _, _ in
                JevRoutingAnswer(preset: preset, confidence: 0.99)
            })
            router.update(enabled: true, apiKey: "fixture-key")
            let result = await router.route(try makeRequest())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.request.body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, model, preset)
            XCTAssertEqual((object["reasoning"] as? [String: Any])?["effort"] as? String, effort, preset)
            XCTAssertEqual(result.decision?.reason, ModelRoutingReason.routed.rawValue)
        }
    }

    func testLowConfidenceMalformedAndTimeoutKeepBaselineExactly() async throws {
        let cases: [(JevRoutingAnswer?, Error?)] = [
            (JevRoutingAnswer(preset: "luna_max", confidence: 0.79), nil),
            (nil, IntelligentModelRouterError.malformedResponse),
            (nil, IntelligentModelRouterError.timeout)
        ]
        for (answer, error) in cases {
            let router = IntelligentModelRouter(classifier: { _, _ in
                if let error { throw error }
                return answer!
            })
            router.update(enabled: true, apiKey: "fixture-key")
            let request = try makeRequest()
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
            XCTAssertFalse(result.decision?.changed ?? true)
            XCTAssertEqual(result.decision?.originalModel, "gpt-6-astra")
            XCTAssertEqual(result.decision?.selectedModel, "gpt-6-astra")
        }
    }

    func testHTTPSchemaUsesChoiceAnswerAndDoesNotSendRelayHeaders() async throws {
        let capture = RequestCapture()
        let router = IntelligentModelRouter(transport: { request in
            await capture.save(request)
            let response = Data("""
            {"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"sol_high","probabilities":{"sol_high":0.95,"keep":0.05},"confidence":0.95}},"usage":{"input_tokens":1,"output_tokens":1}}
            """.utf8)
            return IntelligentModelRouterHTTPResponse(statusCode: 200, data: response)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let result = await router.route(try makeRequest(headers: [
            "thread-id": "thread-secret", "authorization": "Bearer relay-secret",
            "x-codex-turn-metadata": "{\"thread_id\":\"thread-secret\",\"turn_id\":\"turn-1\",\"request_kind\":\"turn\"}"
        ]))

        XCTAssertEqual(result.decision?.selectedModel, "gpt-5.6-sol")
        let captured = await capture.value
        let sent = try XCTUnwrap(captured)
        XCTAssertEqual(sent.url?.absoluteString, IntelligentModelRouter.endpoint.absoluteString)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try XCTUnwrap(sent.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(state["latest_user_text"] as? String, "Change the specified button label and verify the UI.")
        XCTAssertNil(state["authorization"])
        XCTAssertNil(state["thread-id"])
        XCTAssertEqual((body["model"] as? String), "jev-1.13.0")
        let question = try XCTUnwrap((body["questions"] as? [String: Any])?["route"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertTrue((question["criteria"] as? [String: Any])?.keys.contains("luna_max") == true)
    }

    func testUnrelatedFieldsRemainAndContinuationReusesDecisionOnce() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_max", confidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let headers = [
            "thread-id": "thread-1",
            "x-codex-turn-metadata": "{\"thread_id\":\"thread-1\",\"turn_id\":\"turn-1\",\"request_kind\":\"turn\"}"
        ]
        let initial = try makeRequest(headers: headers, body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium", "summary": "auto"],
            "input": [["role": "user", "content": [["type": "input_text", "text": "Implement the change."]]]],
            "metadata": ["keep": "this"], "tools": [["type": "function"]]
        ])
        let routed = await router.route(initial)
        let routedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: routed.request.body) as? [String: Any])
        XCTAssertEqual(routedObject["metadata"] as? [String: String], ["keep": "this"])
        XCTAssertEqual((routedObject["reasoning"] as? [String: Any])?["summary"] as? String, "auto")

        let continuation = try makeRequest(headers: headers, body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["type": "function_call_output", "call_id": "1", "output": "done"]]
        ])
        let continued = await router.route(continuation)
        XCTAssertEqual(continued.decision?.reason, ModelRoutingReason.continuationReused.rawValue)
        let continuedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: continued.request.body) as? [String: Any])
        let routedObjectAgain = try XCTUnwrap(try JSONSerialization.jsonObject(with: routed.request.body) as? [String: Any])
        XCTAssertEqual(continuedObject["model"] as? String, routedObjectAgain["model"] as? String)
        XCTAssertEqual((continuedObject["reasoning"] as? [String: Any])?["effort"] as? String,
                       (routedObjectAgain["reasoning"] as? [String: Any])?["effort"] as? String)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
        router.retainOriginal(for: continuation)
        let retained = await router.route(continuation)
        XCTAssertEqual(retained.request.body, continuation.body)
    }

    func testConcurrentThreadsSingleFlightPerTurnAndSettingsInvalidate() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            try await Task.sleep(for: .milliseconds(40))
            return JevRoutingAnswer(preset: "sol_medium", confidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let first = try makeRequest(thread: "thread-a", turn: "turn-a")
        let second = try makeRequest(thread: "thread-b", turn: "turn-b")
        async let a = router.route(first)
        async let b = router.route(first)
        async let c = router.route(second)
        _ = await (a, b, c)
        let firstCallCount = await calls.value
        XCTAssertEqual(firstCallCount, 2)

        let invalidationRequest = try makeRequest(thread: "thread-c", turn: "turn-c")
        let invalidated = Task.detached { await router.route(invalidationRequest) }
        try await Task.sleep(for: .milliseconds(5))
        router.update(enabled: false, apiKey: nil)
        let result = await invalidated.value
        XCTAssertEqual(result.request.body, invalidationRequest.body)
        XCTAssertFalse(result.decision?.changed ?? true)
    }

    func testUnknownModelAndMultimodalBodyPassThrough() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_max", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let unknown = try makeRequest(body: ["model": "unknown-model", "input": "text"])
        let image = try makeRequest(body: [
            "model": "gpt-6-astra", "input": [["role": "user", "content": [
                ["type": "input_text", "text": "inspect"], ["type": "input_image", "image_url": "https://example.invalid/a.png"]
            ]]]
        ])
        let unknownResult = await router.route(unknown)
        let imageResult = await router.route(image)
        XCTAssertEqual(unknownResult.request.body, unknown.body)
        XCTAssertEqual(imageResult.request.body, image.body)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testInjectedContextOnlyUserItemIsExcludedFromClassifierState() async throws {
        let capture = InputCapture()
        let router = IntelligentModelRouter(classifier: { input, _ in
            await capture.save(input)
            return JevRoutingAnswer(preset: "keep", confidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let request = try makeRequest(body: [
            "model": "gpt-6-astra",
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": "# AGENTS.md instructions\n<environment_context>\ninternal context"]]],
                ["role": "user", "content": [["type": "input_text", "text": "Do the work."]]]
            ]
        ])

        _ = await router.route(request)

        let input = await capture.value
        XCTAssertEqual(input?.latestUserText, "Do the work.")
        XCTAssertNil(input?.priorUserText)
    }

    func testTimeoutCancelsSlowClassifierAndKeepsOriginal() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            try await Task.sleep(for: .seconds(5))
            return JevRoutingAnswer(preset: "luna_max", confidence: 1)
        }, timeout: 0.05)
        router.update(enabled: true, apiKey: "fixture-key")
        let request = try makeRequest()
        let start = ContinuousClock.now
        let result = await router.route(request)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.request.body, request.body)
        XCTAssertEqual(result.decision?.reason, "timeout")
    }

    func testContinuationCannotReuseDifferentTurnOrSharedSession() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_max", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        _ = await router.route(try makeRequest())
        let otherTurn = try makeRequest(turn: "turn-2", body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["type": "function_call_output", "call_id": "1", "output": "done"]]
        ])
        let continued = await router.route(otherTurn)
        XCTAssertEqual(continued.request.body, otherTurn.body)
        let sharedSession = try makeRequest(headers: ["session-id": "shared-root-session"])
        let sessionResult = await router.route(sharedSession)
        XCTAssertEqual(sessionResult.request.body, sharedSession.body)
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testInvalidPresetAndConfidenceNeverRewrite() async throws {
        let answers = [JevRoutingAnswer(preset: "luna_xhigh", confidence: 1),
                       JevRoutingAnswer(preset: "unknown_luna", confidence: 1),
                       JevRoutingAnswer(preset: "luna_max", confidence: 1.1)]
        for answer in answers {
            let router = IntelligentModelRouter(classifier: { _, _ in answer })
            router.update(enabled: true, apiKey: "fixture-key")
            let request = try makeRequest()
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
        }
    }

    func testMalformedProbabilityDistributionsKeepOriginalBody() async throws {
        let distributions: [[String: Double]] = [
            ["luna_medium": 0.1, "keep": 0.9], // choice contradicts winner
            ["keep": 1], // selected label absent
            ["luna_medium": 1.1, "keep": -0.1],
            ["luna_medium": 0.7], // not normalized
            ["luna_medium": 0.99, "unknown": 0.01],
            [:]
        ]
        for distribution in distributions {
            let data = try JSONSerialization.data(withJSONObject: ["answers": ["route": [
                "type": "choice", "choice": "luna_medium", "confidence": 0.99,
                "probabilities": distribution
            ]]])
            let router = IntelligentModelRouter(transport: { _ in
                IntelligentModelRouterHTTPResponse(statusCode: 200, data: data)
            })
            router.update(enabled: true, apiKey: "fixture-key")
            let request = try makeRequest()
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
            XCTAssertEqual(result.decision?.reason, "malformed_response")
        }
    }

    func testCredentialsInLatestOrPriorNeverReachClassifier() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_medium", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let secret = "Authorization: Bearer synthetic-token-for-unit-test-12345"
        for (index, messages) in [[secret], [secret, "이 설정 확인해줘"]].enumerated() {
            let request = try makeRequest(thread: "privacy-\(index)", body: [
                "model": "gpt-6-astra", "reasoning": ["effort": "high"],
                "input": messages.map { ["role": "user", "content": $0] }
            ])
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
            XCTAssertEqual(result.decision?.reason, "sensitive_input")
        }
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    func testRepeatedFollowupWithDifferentContextClassifiesAgain() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { input, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: input.priorUserText == "Translate the supplied paragraph." ? "luna_medium" : "sol_high", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let priorMessages = ["Translate the supplied paragraph.", "Diagnose the intermittent deadlock."]
        var results: [ModelRoutingResult] = []
        for prior in priorMessages {
            results.append(await router.route(try makeRequest(headers: ["thread-id": "same-thread"], body: [
                "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
                "input": [["role": "user", "content": prior], ["role": "user", "content": "진행해줘"]]
            ])))
        }
        XCTAssertEqual(results[0].decision?.selectedModel, "gpt-5.6-luna")
        XCTAssertEqual(results[1].decision?.selectedModel, "gpt-5.6-sol")
        let count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testMixedTextAndUnsupportedAttachmentNeverClassifies() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_medium", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        for type in ["input_file", "future_content_type"] {
            let request = try makeRequest(body: [
                "model": "gpt-6-astra", "input": [["role": "user", "content": [
                    ["type": "input_text", "text": "Summarize the attached report."],
                    ["type": type, "file_id": "fixture-file"]
                ]]]
            ])
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
            XCTAssertEqual(result.decision?.reason, "unsupported_request")
        }
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    func testProtectedFilesPreserveIncomingModelWithoutClassifier() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_medium", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        for model in ["gpt-6-astra", "gpt-5.6-luna"] {
            let request = try makeRequest(body: ["model": model, "reasoning": ["effort": "high"],
                "input": "Implement validation. Do not change or remove the existing tests or AGENTS.md."])
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
            XCTAssertEqual(result.decision?.reason, "protected_files")
        }
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    private func makeRequest(thread: String = "thread-1", turn: String = "turn-1",
                             headers: [String: String]? = nil,
                             body: [String: Any]? = nil) throws -> RelayRequest {
        let actualHeaders = headers ?? [
            "thread-id": thread,
            "x-codex-turn-metadata": "{\"thread_id\":\"\(thread)\",\"turn_id\":\"\(turn)\",\"request_kind\":\"turn\"}"
        ]
        let actualBody = body ?? [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["role": "user", "content": [["type": "input_text", "text": "Change the specified button label and verify the UI."]]]],
            "stream": true
        ]
        return RelayRequest(method: "POST", target: "/backend-api/codex/responses",
                            headers: actualHeaders, body: try JSONSerialization.data(withJSONObject: actualBody))
    }
}

private actor CallCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}

private actor RequestCapture {
    private var request: URLRequest?
    func save(_ request: URLRequest) { self.request = request }
    var value: URLRequest? { request }
}

private actor InputCapture {
    private var input: JevRoutingInput?
    func save(_ input: JevRoutingInput) { self.input = input }
    var value: JevRoutingInput? { input }
}
