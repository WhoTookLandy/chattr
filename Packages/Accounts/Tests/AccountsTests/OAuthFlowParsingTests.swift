#if canImport(UIKit)
import Testing
import Foundation
import Core
@testable import Accounts

/// Coverage for `OAuthFlow.parseCallbackURL` — the bridge-callback parser
/// that turns `chattr://oauth-complete?...` into an `OAuthToken`. Extracted
/// from the `ASWebAuthenticationSession` handler precisely so its branch tree
/// can be tested without standing up a web-auth session.
@Suite("OAuthFlow.parseCallbackURL")
struct OAuthFlowParsingTests {

    @Test("success URL yields a fully populated token")
    func successFull() throws {
        let url = URL(string: "chattr://oauth-complete?access_token=at-1&refresh_token=rt-1&expires_in=14400&scope=chat:read%20chat:edit&token_type=bearer")!
        let token = try OAuthFlow.parseCallbackURL(url)
        #expect(token.accessToken == "at-1")
        #expect(token.refreshToken == "rt-1")
        #expect(token.expiresIn == 14400)
        #expect(token.scope == ["chat:read", "chat:edit"])
        #expect(token.tokenType == "bearer")
    }

    @Test("success URL with only access_token leaves optionals nil")
    func successMinimal() throws {
        let url = URL(string: "chattr://oauth-complete?access_token=at-only")!
        let token = try OAuthFlow.parseCallbackURL(url)
        #expect(token.accessToken == "at-only")
        #expect(token.refreshToken == nil)
        #expect(token.expiresIn == nil)
        #expect(token.scope == nil)
        #expect(token.tokenType == nil)
    }

    @Test("empty refresh_token / token_type collapse to nil")
    func emptyOptionalsBecomeNil() throws {
        let url = URL(string: "chattr://oauth-complete?access_token=at-1&refresh_token=&token_type=")!
        let token = try OAuthFlow.parseCallbackURL(url)
        #expect(token.refreshToken == nil)
        #expect(token.tokenType == nil)
    }

    @Test("error param throws AppError carrying the description")
    func errorWithDescription() {
        let url = URL(string: "chattr://oauth-complete?error=access_denied&error_description=User%20denied%20access")!
        let error = #expect(throws: AppError.self) {
            try OAuthFlow.parseCallbackURL(url)
        }
        #expect(error?.message == "User denied access")
    }

    @Test("error param without a description falls back to the error code")
    func errorWithoutDescription() {
        let url = URL(string: "chattr://oauth-complete?error=access_denied")!
        let error = #expect(throws: AppError.self) {
            try OAuthFlow.parseCallbackURL(url)
        }
        #expect(error?.message == "access_denied")
    }

    @Test("missing access_token throws")
    func missingAccessToken() {
        let url = URL(string: "chattr://oauth-complete?refresh_token=rt-1")!
        #expect(throws: AppError.self) {
            try OAuthFlow.parseCallbackURL(url)
        }
    }

    @Test("present-but-empty access_token throws")
    func emptyAccessToken() {
        let url = URL(string: "chattr://oauth-complete?access_token=")!
        #expect(throws: AppError.self) {
            try OAuthFlow.parseCallbackURL(url)
        }
    }
}
#endif
