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
                     body: try JSONSerialization.data(withJSONObject: ["model": "gpt-6-astra", "input": items]))
    }
    private func router() -> IntelligentModelRouter {
        let value = IntelligentModelRouter(classifier: { _, _ in JevRoutingAnswer(preset: "luna_medium", confidence: 0.99) })
        value.update(enabled: true, apiKey: "fixture")
        return value
    }
    func testIndependentTextAfterHistoricalImageRoutes() async throws {
        let result = await router().route(try request([visual, user("Calculate 12 + 34. Return only the number.")]))
        XCTAssertEqual(result.decision?.reason, "routed")
        XCTAssertEqual(result.decision?.selectedModel, "gpt-5.6-luna")
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
    func testNewUnknownAttachmentStillExcluded() async throws {
        let file: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": "Read the report"], ["type": "input_file", "file_id": "fixture"]]]
        let result = await router().route(try request([visual, file]))
        XCTAssertEqual(result.decision?.reason, "unsupported_request")
    }
}
