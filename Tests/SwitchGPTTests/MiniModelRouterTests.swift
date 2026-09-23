import XCTest
@testable import SwitchGPT

final class MiniModelRouterTests: XCTestCase {
    func testMiniLowMapsToLunaLowAndPreservesOtherFields() throws {
        let body: [String: Any] = [
            "model": "gpt-5.4-mini", "reasoning": ["effort": "low", "summary": "auto"],
            "input": "Hello", "extra": ["nested": true]
        ]
        let request = try makeRequest(body)
        let routed = MiniModelRouter.route(request)
        var expected = body
        expected["model"] = "gpt-6-luna"
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: routed.request.body) as? NSDictionary)
        XCTAssertEqual(actual, expected as NSDictionary)
        XCTAssertEqual(routed.decision?.originalModel, "gpt-5.4-mini")
        XCTAssertEqual(routed.decision?.selectedEffort, "low")
        XCTAssertEqual(routed.decision?.changed, true)
    }

    func testOtherModelsAndEffortsRemainByteForByteUnchanged() throws {
        for (model, effort) in [("gpt-5.4-mini", "medium"), ("gpt-5.4-mini", "high"),
                                ("gpt-6-sol", "low"), ("gpt-6-astra", "medium")] {
            let request = try makeRequest(["model": model, "reasoning": ["effort": effort]])
            let routed = MiniModelRouter.route(request)
            XCTAssertEqual(routed.request.body, request.body)
            XCTAssertEqual(routed.request.headers, request.headers)
            XCTAssertNil(routed.decision)
        }
    }

    func testUnsupportedEncodingPreservesOriginal() throws {
        let request = RelayRequest(method: "POST", target: "/backend-api/codex/responses",
                                   headers: ["content-encoding": "gzip"], body: Data("opaque".utf8))
        let routed = MiniModelRouter.route(request)
        XCTAssertEqual(routed.request.body, request.body)
        XCTAssertNil(routed.decision)
    }

    func testLegacyPreferencesKeepAccountSwitchingWithoutRemovedSettings() throws {
        let old = Data(#"{"automatic":false,"effortAutomatic":true,"modelAutomatic":true,"desktopVerified":true}"#.utf8)
        let preferences = try JSONDecoder().decode(RoutingPreferences.self, from: old)
        XCTAssertFalse(preferences.automatic)
        XCTAssertTrue(preferences.desktopVerified)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        XCTAssertNil(saved["effortAutomatic"])
        XCTAssertNil(saved["modelAutomatic"])
    }

    func testOnlyMiniMappingCanAppearAsCurrentRoute() {
        let old = ModelRoutingDecision(originalModel: "gpt-6-astra", originalEffort: "medium",
                                       selectedModel: "gpt-6-astra", selectedEffort: "low", reason: "routed")
        XCTAssertFalse(old.isMiniMapping)
        let mini = ModelRoutingDecision(originalModel: "gpt-5.4-mini", originalEffort: "low",
                                        selectedModel: "gpt-6-luna", selectedEffort: "low", reason: "routed")
        XCTAssertTrue(mini.isMiniMapping)
    }

    private func makeRequest(_ object: [String: Any]) throws -> RelayRequest {
        RelayRequest(method: "POST", target: "/backend-api/codex/responses",
                     headers: [:], body: try JSONSerialization.data(withJSONObject: object))
    }
}
