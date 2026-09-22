import XCTest
@testable import SwitchGPT

final class UsageBarToneTests: XCTestCase {
    func testRemainingThresholds() {
        XCTAssertEqual(UsageBarTone.resolve(remaining: 0), .critical)
        XCTAssertEqual(UsageBarTone.resolve(remaining: 9.99), .critical)
        XCTAssertEqual(UsageBarTone.resolve(remaining: 10), .warning)
        XCTAssertEqual(UsageBarTone.resolve(remaining: 19.99), .warning)
        XCTAssertEqual(UsageBarTone.resolve(remaining: 20), .normal)
        XCTAssertEqual(UsageBarTone.resolve(remaining: 100), .normal)
    }
}
