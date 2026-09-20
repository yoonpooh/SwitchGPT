import XCTest
@testable import SwitchGPT

final class RoutingInputPrivacyTests: XCTestCase {
    func testDetectsExplicitCredentialShapes() {
        let cases = [
            "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc1234567890.signature",
            "Authorization: Bearer synthetic-token-for-unit-test-12345",
            "Authorization:Bearer ghp_0123456789abcdefghijklmnopqrstuv",
            "API_KEY=sk-proj-0123456789abcdefghijklmnop",
            "access_token: a1b2c3d4e5f6g7h8i9j0-k1l2m3n4",
            "password: MySecretPassword123",
            "password: useful-exampleWord-Password123",
            "ghp_exampleRealCredential01234567890123456789",
            "비밀번호: 안전한-비밀번호-12345",
            "https://deploy-user:p-ssw0rd-long@example.com/repository",
            "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcw\n-----END PRIVATE KEY-----"
        ]

        for value in cases {
            XCTAssertTrue(RoutingInputPrivacy.containsCredential(value), value)
        }
    }

    func testIgnoresPlaceholdersAndOrdinaryRequests() {
        let cases = [
            "What does an API key do?",
            "Please set the password for the test account.",
            "API_KEY=YOUR_API_KEY",
            "access_token=<...>",
            "password: REDACTED",
            "Authorization: Bearer example-token-value-1234567890",
            "https://user:password@example.com/repository",
            "https://example.com/docs#api-key",
            "ghp_example0000000000000000000000000000",
            "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcD\n-----END PUBLIC KEY-----",
            "The migration changes API_KEY naming in the documentation."
        ]

        for value in cases {
            XCTAssertFalse(RoutingInputPrivacy.containsCredential(value), value)
        }
    }

    func testRecognizesOnlyLongOpaqueTokenShapes() {
        XCTAssertFalse(RoutingInputPrivacy.containsCredential("sk-short"))
        XCTAssertFalse(RoutingInputPrivacy.containsCredential("AKIA1234"))
        XCTAssertFalse(RoutingInputPrivacy.containsCredential("Bearer token"))
        XCTAssertTrue(RoutingInputPrivacy.containsCredential("sk-0123456789abcdefghijklmnop"))
        XCTAssertTrue(RoutingInputPrivacy.containsCredential("github_pat_11AAAAAA111111111111111111111111111111"))
        XCTAssertTrue(RoutingInputPrivacy.containsCredential("AKIA1234567890ABCDEF"))
    }

    func testCanRunConcurrentlyWithoutSharedState() async {
        let inputs = [
            "API_KEY=YOUR_API_KEY",
            "API_KEY=0123456789abcdefghijkl",
            "What is an API key?",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc1234567890.signature"
        ]

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for input in inputs {
                group.addTask {
                    RoutingInputPrivacy.containsCredential(input)
                }
            }

            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.filter { $0 }.count, 2)
    }
}
