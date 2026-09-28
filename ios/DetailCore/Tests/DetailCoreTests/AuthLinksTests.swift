import XCTest
@testable import DetailCore

final class AuthLinksTests: XCTestCase {

    /// A sign-up confirmation must open the web's /auth/callback page: the
    /// web refuses (and scrubs) link tokens anywhere else, so a link to the
    /// Site URL root left the person on the sign-in page, not signed in.
    func testSignUpConfirmationsOpenTheWebCallbackPage() throws {
        let base = try XCTUnwrap(URL(string: "https://app.example.com"))
        XCTAssertEqual(
            AuthLinks.signUpConfirmation(webAppBase: base)?.absoluteString,
            "https://app.example.com/auth/callback"
        )
    }

    func testATrailingSlashOnTheBaseIsNotDoubled() throws {
        let base = try XCTUnwrap(URL(string: "https://app.example.com/"))
        XCTAssertEqual(
            AuthLinks.signUpConfirmation(webAppBase: base)?.absoluteString,
            "https://app.example.com/auth/callback"
        )
        XCTAssertEqual(
            AuthLinks.passwordReset(webAppBase: base)?.absoluteString,
            "https://app.example.com/reset-password"
        )
    }

    func testTheSlashInTheCallbackPathIsNotEscaped() throws {
        let base = try XCTUnwrap(URL(string: "https://app.example.com"))
        let url = try XCTUnwrap(AuthLinks.signUpConfirmation(webAppBase: base))
        XCTAssertEqual(url.path, "/auth/callback")
        XCTAssertFalse(url.absoluteString.contains("%2F"))
    }

    func testPasswordResetsOpenTheResetPage() throws {
        let base = try XCTUnwrap(URL(string: "https://app.example.com"))
        XCTAssertEqual(
            AuthLinks.passwordReset(webAppBase: base)?.absoluteString,
            "https://app.example.com/reset-password"
        )
    }

    func testWithoutAWebAppURLNoRedirectIsSent() {
        XCTAssertNil(AuthLinks.signUpConfirmation(webAppBase: nil))
        XCTAssertNil(AuthLinks.passwordReset(webAppBase: nil))
    }
}
