import XCTest
@testable import SwitchGPT

final class ProfileImageTests: XCTestCase {
    func testProfileImageCredentialsStayOnTrustedOrigin() {
        XCTAssertTrue(UsageClient.isTrustedImageURL(URL(string: "https://chatgpt.com/backend-api/estuary/content?id=example")!))
        for value in ["http://chatgpt.com/image", "https://chatgpt.com.example.org/image", "https://example.org/image", "https://chatgpt.com:444/image", "https://user@chatgpt.com/image"] {
            XCTAssertFalse(UsageClient.isTrustedImageURL(URL(string: value)!), value)
        }
    }
}
