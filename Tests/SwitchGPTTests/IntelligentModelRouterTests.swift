import XCTest
@testable import SwitchGPT

final class IntelligentModelRouterTests: XCTestCase {
    func testMiniLowAlwaysRoutesToLunaLowWithoutClassifier() async throws {
        let calls = CallCounter()
        for enabled in [false, true] {
            for routeModel in [false, true] {
                let router = IntelligentModelRouter(classifier: { _, _ in
                    await calls.increment()
                    return JevRoutingAnswer(preset: "astra_high", confidence: 1)
                })
                router.update(enabled: enabled, apiKey: enabled ? "fixture-key" : nil,
                              routeModel: routeModel, routeEffort: true)
                let body: [String: Any] = [
                    "model": "gpt-5.4-mini", "reasoning": ["effort": "low", "summary": "auto"],
                    "input": "Hello", "extra": ["nested": true]
                ]
                let request = try makeRequest(body: body)
                let result = await router.route(request)
                var expected = body
                expected["model"] = "gpt-5.6-luna"
                let actual = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.request.body) as? NSDictionary)
                XCTAssertEqual(actual, expected as NSDictionary)
                XCTAssertEqual(result.decision?.originalModel, "gpt-5.4-mini")
                XCTAssertEqual(result.decision?.selectedEffort, "low")
                XCTAssertEqual(result.decision?.changed, true)
            }
        }
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    func testMiniMappingLeavesOtherModelEffortPairsUnchanged() async throws {
        let router = IntelligentModelRouter()
        for (model, effort) in [("gpt-5.4-mini", "medium"), ("gpt-5.4-mini", "high"),
                                ("gpt-5.4-mini", nil), ("gpt-5.6-luna", "low"),
                                ("gpt-6-astra", "low")] as [(String, String?)] {
            var body: [String: Any] = ["model": model, "input": "Hello"]
            if let effort { body["reasoning"] = ["effort": effort] }
            let request = try makeRequest(body: body)
            let result = await router.route(request)
            XCTAssertEqual(result.request.body, request.body)
            XCTAssertEqual(result.decision?.changed, false)
        }
    }

    func testAdaptiveEffortKeepsInboundSolAndLunaModelsAndCanDowngradeToLow() async throws {
        for model in ["gpt-5.6-sol", "gpt-5.6-luna"] {
            let router = IntelligentModelRouter(classifier: { _, _ in
                JevRoutingAnswer(model: "astra", effort: "low", modelConfidence: 0.99,
                                 effortConfidence: 0.99, horizon: 1)
            })
            router.update(enabled: true, apiKey: "fixture-key", routeModel: true, routeEffort: true)
            let result = await router.route(try makeRequest(body: [
                "model": model, "reasoning": ["effort": "medium"], "input": "Routine follow-up"
            ]))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.request.body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, model)
            XCTAssertEqual((object["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        }
    }

    func testTruncationAndContextManagementStillAllowRequestLevelEffortRouting() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: nil, effort: "low", modelConfidence: nil,
                             effortConfidence: 0.99, horizon: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let result = await router.route(try makeRequest(body: [
            "model": "gpt-5.6-sol",
            "reasoning": ["effort": "medium"],
            "input": "Routine follow-up",
            "truncation": "auto",
            "context_management": [["type": "compaction", "compact_threshold": 100_000]]
        ]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.request.body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual((object["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testHorizonOneReassessesOnFirstToolContinuation() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            let count = await calls.incrementAndReturn()
            return JevRoutingAnswer(model: nil, effort: count == 1 ? "high" : "low",
                                    modelConfidence: nil, effortConfidence: 0.99, horizon: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let headers = ["thread-id": "horizon-one",
                       "x-codex-turn-metadata": "{\"thread_id\":\"horizon-one\",\"turn_id\":\"turn-1\"}"]
        _ = await router.route(try makeRequest(headers: headers))
        let continuation = await router.route(try makeRequest(headers: headers, body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["type": "function_call_output", "output": "done"]]
        ]))
        XCTAssertEqual((try XCTUnwrap(try JSONSerialization.jsonObject(with: continuation.request.body) as? [String: Any])["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let horizonOneCalls = await calls.value
        XCTAssertEqual(horizonOneCalls, 2)
    }

    func testHorizonReuseThenExpiryReassesses() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            let count = await calls.incrementAndReturn()
            return JevRoutingAnswer(model: nil, effort: count == 1 ? "high" : "low",
                                    modelConfidence: nil, effortConfidence: 0.99, horizon: 2)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let headers = ["thread-id": "horizon-two",
                       "x-codex-turn-metadata": "{\"thread_id\":\"horizon-two\",\"turn_id\":\"turn-1\"}"]
        _ = await router.route(try makeRequest(headers: headers))
        let body: [String: Any] = ["model": "gpt-6-astra", "reasoning": ["effort": "medium"],
                                    "input": [["type": "function_call_output", "output": "done"]]]
        let reused = await router.route(try makeRequest(headers: headers, body: body))
        XCTAssertEqual(reused.decision?.reason, ModelRoutingReason.continuationReused.rawValue)
        let reuseCalls = await calls.value
        XCTAssertEqual(reuseCalls, 1)
        let expired = await router.route(try makeRequest(headers: headers, body: body))
        XCTAssertEqual(expired.decision?.selectedEffort, "low")
        let expiryCalls = await calls.value
        XCTAssertEqual(expiryCalls, 2)
    }

    func testFailureToolOutputBypassesRemainingHorizon() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            let count = await calls.incrementAndReturn()
            return JevRoutingAnswer(model: nil, effort: count == 1 ? "high" : "low",
                                    modelConfidence: nil, effortConfidence: 0.99, horizon: 10)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let headers = ["thread-id": "failure-turn",
                       "x-codex-turn-metadata": "{\"thread_id\":\"failure-turn\",\"turn_id\":\"turn-1\"}"]
        _ = await router.route(try makeRequest(headers: headers))
        let result = await router.route(try makeRequest(headers: headers, body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["type": "function_call_output", "output": "error: exit_code=1"]]
        ]))
        XCTAssertEqual(result.decision?.selectedEffort, "low")
        let failureCalls = await calls.value
        XCTAssertEqual(failureCalls, 2)
    }

    func testExplicitSubagentBypassesAdaptiveEffort() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(model: nil, effort: "low", modelConfidence: nil,
                                    effortConfidence: 1, horizon: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let result = await router.route(try makeRequest(headers: [
            "thread-id": "subagent", "x-openai-subagent": "true",
            "x-codex-turn-metadata": "{\"thread_id\":\"subagent\",\"turn_id\":\"turn-1\"}"
        ]))
        XCTAssertEqual(result.decision?.reason, ModelRoutingReason.explicitSubagent.rawValue)
        let subagentCalls = await calls.value
        XCTAssertEqual(subagentCalls, 0)
    }

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
            ("luna_medium", "gpt-6-astra", "medium"),
            ("luna_max", "gpt-6-astra", "max"),
            ("sol_medium", "gpt-6-astra", "medium"),
            ("sol_high", "gpt-6-astra", "high"),
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

    func testModelAndEffortCanRouteIndependently() async throws {
        let modelOnly = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "max", modelConfidence: 0.99, effortConfidence: 0.99)
        })
        modelOnly.update(enabled: true, apiKey: "fixture-key", routeModel: true, routeEffort: false)
        let modelResult = await modelOnly.route(try makeRequest())
        let modelObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: modelResult.request.body) as? [String: Any])
        XCTAssertEqual(modelObject["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((modelObject["reasoning"] as? [String: Any])?["effort"] as? String, "medium")

        let effortOnly = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "keep", effort: "high", modelConfidence: 0.99, effortConfidence: 0.99)
        })
        effortOnly.update(enabled: true, apiKey: "fixture-key", routeModel: false, routeEffort: true)
        let effortResult = await effortOnly.route(try makeRequest())
        let effortObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: effortResult.request.body) as? [String: Any])
        XCTAssertEqual(effortObject["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((effortObject["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    }

    func testIndependentConfidenceKeepsOnlyTheUncertainDimension() async throws {
        let modelUncertain = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.79, effortConfidence: 0.99)
        })
        modelUncertain.update(enabled: true, apiKey: "fixture-key")
        let effortResult = await modelUncertain.route(try makeRequest())
        let effortObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: effortResult.request.body) as? [String: Any])
        XCTAssertEqual(effortObject["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((effortObject["reasoning"] as? [String: Any])?["effort"] as? String, "high")

        let effortUncertain = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.99, effortConfidence: 0.64)
        })
        effortUncertain.update(enabled: true, apiKey: "fixture-key")
        let modelResult = await effortUncertain.route(try makeRequest())
        let modelObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: modelResult.request.body) as? [String: Any])
        XCTAssertEqual(modelObject["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((modelObject["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
    }

    func testSameBaselineStaysRoutedButUnknownEffortIsKept() async throws {
        let sameBaseline = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "astra", effort: "medium", modelConfidence: 0.99,
                             effortConfidence: 0.99)
        })
        sameBaseline.update(enabled: true, apiKey: "fixture-key")
        let sameResult = await sameBaseline.route(try makeRequest())
        XCTAssertEqual(sameResult.decision?.reason, ModelRoutingReason.routed.rawValue)
        XCTAssertFalse(sameResult.decision?.changed ?? true)

        let unsupportedPair = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "astra", effort: "max", modelConfidence: 0.99,
                             effortConfidence: 0.99)
        })
        unsupportedPair.update(enabled: true, apiKey: "fixture-key")
        let unsupportedRequest = try makeRequest(body: ["model": "gpt-6-astra", "reasoning": ["effort": "xhigh"], "input": "Explain the algorithm"])
        let rejectedResult = await unsupportedPair.route(unsupportedRequest)
        XCTAssertEqual(rejectedResult.decision?.reason, ModelRoutingReason.keep.rawValue)
        XCTAssertFalse(rejectedResult.decision?.changed ?? true)
        XCTAssertEqual(rejectedResult.request.body, unsupportedRequest.body)
    }

    func testLiveIndependentEffortUsesSupportedCombinations() async throws {
        for (family, model, effort) in [("luna", "gpt-5.6-luna", "high"),
                                         ("sol", "gpt-5.6-sol", "max"),
                                         ("astra", "gpt-6-astra", "max")] {
            let response = try JSONSerialization.data(withJSONObject: ["answers": [
                "model": ["type": "choice", "choice": family, "confidence": 0.99,
                          "probabilities": [family: 0.99, "keep": 0.01]],
                "effort": ["type": "choice", "choice": effort, "confidence": 0.99,
                           "probabilities": [effort: 0.99, "keep": 0.01]]
            ]])
            let router = IntelligentModelRouter(transport: { _ in
                IntelligentModelRouterHTTPResponse(statusCode: 200, data: response)
            })
            router.update(enabled: true, apiKey: "fixture-key", routeModel: false, routeEffort: true)
            let request = try makeRequest(body: ["model": model, "reasoning": ["effort": "medium"],
                                                  "input": "Explain this algorithm"])
            let result = await router.route(request)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.request.body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, model)
            XCTAssertEqual((object["reasoning"] as? [String: Any])?["effort"] as? String, effort)
            XCTAssertEqual(result.decision?.reason, "routed")
        }
    }

    func testLiveKeepOnEitherDimensionPreservesTheWholeBaseline() async throws {
        let response = Data("""
        {"answers":{"model":{"type":"choice","choice":"luna","probabilities":{"luna":0.99,"keep":0.01},"confidence":0.99},"effort":{"type":"choice","choice":"keep","probabilities":{"keep":0.99,"high":0.01},"confidence":0.99}}}
        """.utf8)
        let router = IntelligentModelRouter(transport: { _ in
            IntelligentModelRouterHTTPResponse(statusCode: 200, data: response)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let request = try makeRequest()
        let result = await router.route(request)
        XCTAssertEqual(result.request.body, request.body)
        XCTAssertEqual(result.decision?.reason, ModelRoutingReason.keep.rawValue)
    }

    func testLowConfidenceMalformedAndTimeoutKeepBaselineExactly() async throws {
        let cases: [(JevRoutingAnswer?, Error?)] = [
            (JevRoutingAnswer(preset: "luna_max", confidence: 0.64), nil),
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
            {"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"sol","probabilities":{"sol":0.95,"keep":0.05},"confidence":0.95},"effort":{"type":"choice","choice":"high","probabilities":{"high":0.95,"keep":0.05},"confidence":0.95}},"usage":{"input_tokens":1,"output_tokens":1}}
            """.utf8)
            return IntelligentModelRouterHTTPResponse(statusCode: 200, data: response)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let result = await router.route(try makeRequest(headers: [
            "thread-id": "thread-secret", "authorization": "Bearer relay-secret",
            "x-codex-turn-metadata": "{\"thread_id\":\"thread-secret\",\"turn_id\":\"turn-1\",\"request_kind\":\"turn\"}"
        ]))

        XCTAssertEqual(result.decision?.selectedModel, "gpt-6-astra")
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
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertNil(questions["model"])
        let effortQuestion = try XCTUnwrap(questions["effort"] as? [String: Any])
        XCTAssertEqual(effortQuestion["type"] as? String, "choice")
        XCTAssertNotNil(questions["horizon"] as? [String: Any])
    }

    func testUnrelatedFieldsRemainAndContinuationReusesDecisionOnce() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_max", confidence: 0.99, horizon: 2)
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
        XCTAssertEqual(retained.decision?.selectedModel, "gpt-6-astra")
        XCTAssertEqual(retained.decision?.selectedEffort, "max")
        let retainedCalls = await calls.value
        XCTAssertEqual(retainedCalls, 2)
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

    @available(macOS 15.0, *)
    func testSingleFlightRetainOriginalPreservesNewSameTurnRequests() async throws {
        let executor = RoutingTestExecutor()
        let classifier = RoutingTestClassifierGate()
        let router = IntelligentModelRouter(classifier: { _, _ in await classifier.answer() }, timeout: 60)
        router.update(enabled: true, apiKey: "fixture-key")
        let request = try makeRequest()
        let first = Task.detached(executorPreference: executor) {
            classifier.routeStarted()
            return await router.route(request)
        }
        let second = Task.detached(executorPreference: executor) {
            classifier.routeStarted()
            return await router.route(request)
        }

        // Exhaust every runnable job while classification is blocked. Both route calls
        // have reached task.value; neither can be satisfied by a completed cache entry.
        executor.runUntilIdle()
        XCTAssertEqual(classifier.startedRoutes, 2)
        XCTAssertEqual(classifier.count, 1)
        classifier.releaseAll(JevRoutingAnswer(preset: "luna_max", confidence: 0.99))
        executor.runAutomatically()
        let results = await [first.value, second.value]
        for result in results {
            XCTAssertEqual(result.decision?.selectedModel, "gpt-6-astra")
            XCTAssertEqual(result.decision?.selectedEffort, "max")
        }
        XCTAssertEqual(classifier.count, 1)

        // ModelRelay calls this on a capability rejection. The turn is marked for an
        // early re-evaluation on its next request; no second request is admitted here while
        // the gate is intentionally closed.
        router.retainOriginal(for: request)
        XCTAssertEqual(classifier.count, 1)
    }

    func testNewSameTurnRequestsReflectModelAndEffortSettingChanges() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "sol_high", confidence: 0.99)
        })
        let request = try makeRequest()
        for (model, effort, expectedModel, expectedEffort) in [
            (true, true, "gpt-6-astra", "high"),
            (false, true, "gpt-6-astra", "high"),
            (true, false, "gpt-6-astra", "medium"),
            (false, false, "gpt-6-astra", "medium")
        ] {
            router.update(enabled: true, apiKey: "fixture-key", routeModel: model, routeEffort: effort)
            let result = await router.route(request)
            XCTAssertEqual(result.decision?.selectedModel, expectedModel)
            XCTAssertEqual(result.decision?.selectedEffort, expectedEffort)
            if !model && !effort { XCTAssertEqual(result.request.body, request.body) }
        }
        let count = await calls.value
        XCTAssertEqual(count, 2) // Only generations with effort routing enabled classify.
    }

    @available(macOS 15.0, *)
    func testSettingsChangeDuringSingleFlightCannotRepopulateOldGeneration() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(model: nil, effort: "high", modelConfidence: nil,
                                    effortConfidence: 0.99, horizon: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key", routeModel: true, routeEffort: true)
        let request = try makeRequest()
        let first = await router.route(request)
        XCTAssertEqual(first.decision?.selectedModel, "gpt-6-astra")
        XCTAssertEqual(first.decision?.selectedEffort, "high")

        // Settings update invalidates the cached generation. The compatibility routeModel flag
        // does not re-enable model hopping in the new generation.
        router.update(enabled: true, apiKey: "fixture-key", routeModel: false, routeEffort: true)
        let fresh = await router.route(request)
        XCTAssertEqual(fresh.decision?.selectedModel, "gpt-6-astra")
        XCTAssertEqual(fresh.decision?.selectedEffort, "high")
        let count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testUnknownModelAndMultimodalBodyPassThrough() async throws {
        let calls = CallCounter()
        let router = IntelligentModelRouter(classifier: { _, _ in
            await calls.increment()
            return JevRoutingAnswer(preset: "luna_max", confidence: 1)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let unknown = try makeRequest(body: ["model": "gpt-5.4-codex", "input": "text"])
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
            ["luna": 0.1, "keep": 0.9], // choice contradicts winner
            ["keep": 1], // selected label absent
            ["luna": 1.1, "keep": -0.1],
            ["luna": 0.7], // not normalized
            ["luna": 0.99, "unknown": 0.01],
            [:]
        ]
        for distribution in distributions {
            let data = try JSONSerialization.data(withJSONObject: ["answers": [
                "model": [
                    "type": "choice", "choice": "keep", "confidence": 0.99,
                    "probabilities": ["keep": 1.0]
                ],
                "effort": [
                    "type": "choice", "choice": "medium", "confidence": 0.99,
                    "probabilities": distribution
                ]
            ]])
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

    func testMalformedIndependentAnswerKeepsBothDimensions() async throws {
        let response = Data("""
        {"answers":{"model":{"type":"choice","choice":"luna","probabilities":{"luna":0.99,"keep":0.01},"confidence":0.99},"effort":{"type":"choice","choice":"high","probabilities":{"high":0.7,"keep":0.1},"confidence":0.99}}}
        """.utf8)
        let router = IntelligentModelRouter(transport: { _ in
            IntelligentModelRouterHTTPResponse(statusCode: 200, data: response)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let request = try makeRequest()
        let result = await router.route(request)
        XCTAssertEqual(result.request.body, request.body)
        XCTAssertEqual(result.decision?.reason, ModelRoutingReason.malformedResponse.rawValue)
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
        XCTAssertEqual(results[0].decision?.selectedModel, "gpt-6-astra")
        XCTAssertEqual(results[1].decision?.selectedModel, "gpt-6-astra")
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
    func incrementAndReturn() -> Int { count += 1; return count }
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

/// Manual draining fixes the ordering without sleeps or scheduler-luck assumptions.
/// Once the blocked phase is inspected, a serial queue finishes all remaining jobs.
@available(macOS 15.0, *)
private final class RoutingTestExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "switchgpt.routing-test-executor")
    private var jobs: [UnownedJob] = []
    private var automatic = false

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.lock()
        if automatic {
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        } else {
            jobs.append(job)
        }
        lock.unlock()
    }

    func runUntilIdle() {
        while true {
            lock.lock()
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            lock.unlock()
            guard let job else { return }
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    func runAutomatically() {
        lock.lock()
        automatic = true
        for job in jobs {
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
        jobs.removeAll()
        lock.unlock()
    }
}

private final class RoutingTestClassifierGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<JevRoutingAnswer, Never>] = []
    private var calls = 0
    private var routes = 0
    let secondCallStarted = XCTestExpectation(description: "new generation classification started")

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var startedRoutes: Int { lock.lock(); defer { lock.unlock() }; return routes }

    func routeStarted() {
        lock.lock(); defer { lock.unlock() }
        routes += 1
    }

    func answer() async -> JevRoutingAnswer {
        await withCheckedContinuation { continuation in
            lock.lock()
            calls += 1
            pending.append(continuation)
            if calls == 2 { secondCallStarted.fulfill() }
            lock.unlock()
        }
    }

    func releaseLast(_ answer: JevRoutingAnswer) {
        lock.lock()
        let continuation = pending.popLast()
        lock.unlock()
        continuation?.resume(returning: answer)
    }

    func releaseAll(_ answer: JevRoutingAnswer) {
        lock.lock()
        let continuations = pending
        pending.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: answer) }
    }
}
