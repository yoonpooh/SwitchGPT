import XCTest
@testable import SwitchGPT

final class ModelRoutingDiagnosticsTests: XCTestCase {
    func testOldDecisionLogDecodesWithoutDiagnostics() throws {
        let data = Data(#"{"originalModel":"gpt-6-astra","originalEffort":"medium","selectedModel":"gpt-6-astra","selectedEffort":"medium","reason":"keep"}"#.utf8)

        let decision = try JSONDecoder().decode(ModelRoutingDecision.self, from: data)

        XCTAssertNil(decision.diagnostics)
        XCTAssertEqual(decision.reason, "keep")
    }

    func testDiagnosticsRecordPartialConfidenceAndAppliedDimensions() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.79, effortConfidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-key")

        let result = await router.route(try makeRequest())
        let diagnostics = try XCTUnwrap(result.decision?.diagnostics)

        XCTAssertEqual(diagnostics.proposedModel, "gpt-5.6-luna")
        XCTAssertEqual(diagnostics.proposedEffort, "high")
        XCTAssertEqual(diagnostics.modelConfidence, 0.79)
        XCTAssertEqual(diagnostics.effortConfidence, 0.99)
        XCTAssertNil(diagnostics.modelThreshold)
        XCTAssertEqual(diagnostics.effortThreshold, 0.65)
        XCTAssertEqual(diagnostics.modelDisposition, .disabled)
        XCTAssertEqual(diagnostics.effortDisposition, .applied)
        XCTAssertEqual(result.decision?.selectedModel, "gpt-6-astra")
        XCTAssertEqual(result.decision?.selectedEffort, "high")
    }

    func testGlobalKeepRetainsPerDimensionProposalWithoutApplyingEither() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "keep", effort: "high", modelConfidence: 0.99,
                             effortConfidence: 0.99, preserveBaseline: true)
        })
        router.update(enabled: true, apiKey: "fixture-key")

        let request = try makeRequest()
        let result = await router.route(request)
        let diagnostics = try XCTUnwrap(result.decision?.diagnostics)

        XCTAssertEqual(diagnostics.proposedModel, "keep")
        XCTAssertEqual(diagnostics.proposedEffort, "high")
        XCTAssertEqual(diagnostics.modelDisposition, .globalKeep)
        XCTAssertEqual(diagnostics.effortDisposition, .globalKeep)
        XCTAssertEqual(result.request.body, request.body)
    }

    func testLowConfidenceNoPlanStillCarriesPerDimensionDiagnostics() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.79, effortConfidence: 0.64)
        })
        router.update(enabled: true, apiKey: "fixture-key")

        let result = await router.route(try makeRequest())
        let diagnostics = try XCTUnwrap(result.decision?.diagnostics)

        XCTAssertEqual(result.decision?.reason, ModelRoutingReason.lowConfidence.rawValue)
        XCTAssertEqual(diagnostics.modelDisposition, .disabled)
        XCTAssertEqual(diagnostics.effortDisposition, .lowConfidence)
        XCTAssertNil(diagnostics.modelThreshold)
        XCTAssertEqual(diagnostics.effortThreshold, 0.65)
    }

    func testDiagnosticsRecordIndependentFlagsAndFullyDisabledRouter() async throws {
        let classifierRouter = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.99, effortConfidence: 0.99)
        })
        classifierRouter.update(enabled: true, apiKey: "fixture-key", routeModel: false, routeEffort: true)
        let partial = await classifierRouter.route(try makeRequest())
        let partialDiagnostics = try XCTUnwrap(partial.decision?.diagnostics)

        XCTAssertFalse(partialDiagnostics.routeModel)
        XCTAssertTrue(partialDiagnostics.routeEffort)
        XCTAssertEqual(partialDiagnostics.modelDisposition, .disabled)
        XCTAssertEqual(partialDiagnostics.effortDisposition, .applied)
        XCTAssertNil(partialDiagnostics.modelThreshold)
        XCTAssertEqual(partialDiagnostics.effortThreshold, 0.65)

        let disabledRouter = IntelligentModelRouter(classifier: { _, _ in
            XCTFail("disabled dimensions must not call the classifier")
            return JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 1, effortConfidence: 1)
        })
        disabledRouter.update(enabled: true, apiKey: "fixture-key", routeModel: false, routeEffort: false)
        let disabled = await disabledRouter.route(try makeRequest())
        let disabledDiagnostics = try XCTUnwrap(disabled.decision?.diagnostics)

        XCTAssertEqual(disabledDiagnostics.modelDisposition, .disabled)
        XCTAssertEqual(disabledDiagnostics.effortDisposition, .disabled)
        XCTAssertFalse(disabledDiagnostics.routeModel)
        XCTAssertFalse(disabledDiagnostics.routeEffort)
    }

    func testDiagnosticsExplainUnsupportedIncomingEffort() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "keep", effort: "high", modelConfidence: 0.99, effortConfidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-key")

        let result = await router.route(try makeRequest(body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "xhigh"],
            "input": "Keep the incoming effort if it cannot be safely classified."
        ]))
        let diagnostics = try XCTUnwrap(result.decision?.diagnostics)

        XCTAssertEqual(diagnostics.effortDisposition, .unsupportedBaseline)
        XCTAssertEqual(diagnostics.modelDisposition, .disabled)
        XCTAssertNil(diagnostics.effortThreshold)
        XCTAssertEqual(result.request.body, try makeRequest(body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "xhigh"],
            "input": "Keep the incoming effort if it cannot be safely classified."
        ]).body)
    }

    func testContinuationReusesDiagnosticsFromCachedOutcome() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.99, effortConfidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-key")
        let headers = [
            "thread-id": "diagnostic-thread",
            "x-codex-turn-metadata": "{\"thread_id\":\"diagnostic-thread\",\"turn_id\":\"turn-1\",\"request_kind\":\"turn\"}"
        ]

        let routed = await router.route(try makeRequest(headers: headers))
        let continuation = await router.route(try makeRequest(headers: headers, body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["type": "function_call_output", "call_id": "1", "output": "done"]]
        ]))

        XCTAssertEqual(continuation.decision?.reason, ModelRoutingReason.continuationReused.rawValue)
        XCTAssertEqual(continuation.decision?.diagnostics, routed.decision?.diagnostics)
        XCTAssertEqual(continuation.decision?.diagnostics?.modelDisposition, .disabled)
        XCTAssertEqual(continuation.decision?.diagnostics?.effortDisposition, .applied)
    }

    func testDiagnosticsSerializationContainsNoPromptOrCredential() async throws {
        let router = IntelligentModelRouter(classifier: { _, _ in
            JevRoutingAnswer(model: "luna", effort: "high", modelConfidence: 0.99, effortConfidence: 0.99)
        })
        router.update(enabled: true, apiKey: "fixture-secret-key")
        let result = await router.route(try makeRequest(body: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": "PRIVATE_PROMPT_SHOULD_NOT_BE_LOGGED"
        ]))
        let decision = try XCTUnwrap(result.decision)
        let encoded = String(decoding: try JSONEncoder().encode(decision), as: UTF8.self)

        XCTAssertFalse(encoded.contains("PRIVATE_PROMPT_SHOULD_NOT_BE_LOGGED"))
        XCTAssertFalse(encoded.contains("fixture-secret-key"))
        XCTAssertFalse(encoded.contains("Authorization"))
        XCTAssertTrue(encoded.contains("gpt-5.6-luna"))
        XCTAssertTrue(encoded.contains("high"))
    }

    func testUpstreamRejectionMarksOnlyAppliedDimensions() throws {
        let diagnostics = ModelRoutingDiagnostics(
            proposedModel: "gpt-5.6-luna", proposedEffort: "high",
            modelConfidence: 0.99, effortConfidence: 0.99,
            routeModel: true, routeEffort: true,
            modelThreshold: 0.8, effortThreshold: 0.8,
            modelDisposition: .applied, effortDisposition: .unchanged)

        let rejected = diagnostics.markingUpstreamRejected(originalModel: "gpt-6-astra", originalEffort: "medium")

        XCTAssertEqual(rejected.modelDisposition, .upstreamRejected)
        XCTAssertEqual(rejected.effortDisposition, .unchanged)
    }

    private func makeRequest(headers: [String: String] = [
        "thread-id": "diagnostic-thread",
        "x-codex-turn-metadata": "{\"thread_id\":\"diagnostic-thread\",\"turn_id\":\"turn-1\",\"request_kind\":\"turn\"}"
    ], body: [String: Any] = [
        "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
        "input": [["role": "user", "content": [["type": "input_text", "text": "Change the specified button label and verify the UI."]]]],
        "stream": true
    ]) throws -> RelayRequest {
        RelayRequest(method: "POST", target: "/backend-api/codex/responses", headers: headers,
                     body: try JSONSerialization.data(withJSONObject: body))
    }
}
