import XCTest
@testable import SwitchGPT

final class RoutingInputPolicyTests: XCTestCase {
    func testDirectProtectedFileConstraints() {
        for text in [
            "Implement the helper. Do not change or remove the existing tests or AGENTS.md.",
            "Never edit tests/test_legacy.py. Put new tests elsewhere.",
            "Do not edit \"tests/test_legacy.py\".",
            "Do not modify “schema.json”.",
            "Existing tests/test_config.py is read-only: never edit it.",
            "tests/test_legacy.py and schema.json are immutable: do not edit or append anything.",
            "기존 테스트 파일은 수정하지 마. 새로운 파일에 테스트를 작성해.",
            "보호된 파일 변경 금지."
        ] { XCTAssertTrue(RoutingInputPolicy.preservesProtectedFiles(text), text) }
    }

    func testOrdinaryScopeAndQuotedPoliciesDoNotOptOut() {
        for text in [
            "Change only this function and its tests; do not refactor unrelated code.",
            "Do not run the tests yet.",
            "Summarize this policy: \"Do not change existing tests or protected files.\"",
            "Explain the following code: ```Do not edit tests/test_legacy.py.```",
            "> Do not change existing tests.\nSummarize that instruction.",
            "Change only the README title to Example Setup."
        ] { XCTAssertFalse(RoutingInputPolicy.preservesProtectedFiles(text), text) }
    }
}
