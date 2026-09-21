import XCTest

/// Every caller of `extractAccessToken` asks the same question: is there a
/// secret here I can authenticate with? These cases pin the answers that are
/// easy to get wrong — the ones where the field exists but holds nothing.
final class AccessTokenExtractionTests: XCTestCase {

    private func envelope(accessToken: String) -> String {
        """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"rt","expiresAt":1234567890}}
        """
    }

    func testReturnsTheTokenWhenPresent() {
        XCTAssertEqual(
            ClaudeService.extractAccessToken(from: envelope(accessToken: "sk-ant-oat01-abc")),
            "sk-ant-oat01-abc"
        )
    }

    /// The case this file exists for. An emptied backup keeps the field and
    /// keeps every surrounding attribute, so "the key is there" says nothing.
    /// Handing the empty string on made callers send `Bearer ` and read the
    /// 429 that came back as a rate limit, parking the account for the hour
    /// the server asked for instead of saying it needs re-authenticating.
    func testEmptyAccessTokenCountsAsAbsent() {
        XCTAssertNil(ClaudeService.extractAccessToken(from: envelope(accessToken: "")))
    }

    func testMissingOAuthBlockCountsAsAbsent() {
        XCTAssertNil(ClaudeService.extractAccessToken(from: #"{"other":{"accessToken":"x"}}"#))
    }

    func testNonJSONCountsAsAbsent() {
        XCTAssertNil(ClaudeService.extractAccessToken(from: "not json"))
        XCTAssertNil(ClaudeService.extractAccessToken(from: ""))
    }
}
