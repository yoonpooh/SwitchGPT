import XCTest
@testable import SwitchGPT

final class CreditBalanceTests: XCTestCase {
    private func usage(_ json: String) throws -> AccountUsage {
        try AccountUsage.decode(Data(json.utf8))
    }

    func testCreditFieldsDecodeSeparatelyFromResetCredits() throws {
        let decoded = try usage(#"{"credits":{"has_credits":true,"unlimited":false,"balance":"125.75"},"rate_limit_reset_credits":{"available_count":2}}"#)
        XCTAssertEqual(decoded.credits?.hasCredits, true)
        XCTAssertEqual(decoded.credits?.unlimited, false)
        XCTAssertEqual(decoded.credits?.balance, "125.75")
        XCTAssertEqual(decoded.rateLimitResetCredits?.availableCount, 2)
    }

    func testNumericStringsPreserveRawBalanceAndDisplayRoundedGroupedIntegers() throws {
        let examples = [
            ("125", "125"),
            ("125.75", "126"),
            ("62297.9654760000", "62,298"),
            ("1234.56", "1,235"),
            ("0", "0"),
            ("0.00", "0"),
            ("0.49999999999999999999999999", "0"),
            ("0.5", "1"),
            ("1.49999999999999999999999999", "1"),
            ("1.5", "2"),
            ("1.50000000000000000000000001", "2"),
            ("999.5", "1,000"),
            ("1000.0000", "1,000"),
            ("001234.5000", "1,235"),
            ("000.0000", "0"),
            ("12345678901234567890.123456789", "12,345,678,901,234,567,890"),
            ("99999999999999999999.5", "100,000,000,000,000,000,000")
        ]
        for (value, displayed) in examples {
            let decoded = try usage("{\"credits\":{\"balance\":\"\(value)\"}}")
            let state = CreditBalanceState.resolve(usage: decoded, queryFailed: false)
            XCTAssertEqual(decoded.credits?.balance, value)
            XCTAssertEqual(state, .balance(value))
            XCTAssertEqual(state.text, displayed, "Input balance \(value)")
        }
        let noCredits = try usage(#"{"credits":{"has_credits":false,"balance":"0"}}"#)
        XCTAssertEqual(CreditBalanceState.resolve(usage: noCredits, queryFailed: false), .balance("0"))
    }

    func testMissingAndNullAreUnavailableRatherThanZero() throws {
        for json in [#"{}"#, #"{"credits":null}"#, #"{"credits":{}}"#,
                     #"{"credits":{"has_credits":null,"unlimited":null,"balance":null}}"#,
                     #"{"credits":{"has_credits":false}}"#] {
            let decoded = try usage(json)
            XCTAssertNil(decoded.credits?.balance)
            XCTAssertEqual(CreditBalanceState.resolve(usage: decoded, queryFailed: false), .unavailable)
        }
        XCTAssertEqual(CreditBalanceState.resolve(usage: nil, queryFailed: false), .unavailable)
    }

    func testInvalidBalanceDoesNotAppearAsCreditAmount() throws {
        for value in ["", " ", "private", "NaN", "Infinity", "-1", "$10", "12 credits", "1,000"] {
            let decoded = try usage("{\"credits\":{\"balance\":\"\(value)\"}}")
            XCTAssertEqual(CreditBalanceState.resolve(usage: decoded, queryFailed: false), .unavailable)
        }
    }

    func testUnlimitedAndFailedQueryHavePriorityOverBalance() throws {
        for balance in ["null", "\"0\"", "\"10.5\""] {
            let decoded = try usage("{\"credits\":{\"unlimited\":true,\"balance\":\(balance)}}")
            XCTAssertEqual(CreditBalanceState.resolve(usage: decoded, queryFailed: false), .unlimited)
            XCTAssertEqual(CreditBalanceState.resolve(usage: decoded, queryFailed: true), .failed)
        }
        let cached = try usage(#"{"credits":{"balance":"125"}}"#)
        XCTAssertEqual(CreditBalanceState.resolve(usage: cached, queryFailed: true), .failed)
        XCTAssertEqual(CreditBalanceState.resolve(usage: nil, queryFailed: true), .failed)
    }

    func testNonNumericDisplayStatesUseDistinctLocalizedValues() {
        XCTAssertEqual(CreditBalanceState.unlimited.text, L10n.text("credits_balance_unlimited"))
        XCTAssertEqual(CreditBalanceState.unavailable.text, L10n.text("credits_balance_unavailable"))
        XCTAssertEqual(CreditBalanceState.failed.text, L10n.text("credits_balance_failed"))
        XCTAssertEqual(Set([CreditBalanceState.unlimited.text, CreditBalanceState.unavailable.text,
                            CreditBalanceState.failed.text]).count, 3)
    }
}
