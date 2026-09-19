import Testing
import Foundation
@testable import LLVS

@Suite struct PKCETests {

    @Test func theChallengeMatchesTheExampleInTheSpecification() {
        // RFC 7636 appendix B gives this verifier and the challenge it must produce
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func theChallengeIsSafeToPutInAURL() {
        // Base64url uses - and _ in place of + and /, and drops the = padding
        let pkce = PKCEChallenge()

        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
        #expect(!pkce.challenge.contains("="))
    }

    @Test func everyVerifierIsDifferent() {
        let verifiers = Set((0..<50).map { _ in PKCEChallenge().verifier })

        #expect(verifiers.count == 50)
    }

    @Test func theVerifierIsLongEnoughForTheSpecification() {
        // RFC 7636 section 4.1 requires between 43 and 128 characters
        let pkce = PKCEChallenge()

        #expect(pkce.verifier.count >= 43)
        #expect(pkce.verifier.count <= 128)
    }

    @Test func theSameVerifierAlwaysGivesTheSameChallenge() {
        // The token request sends the verifier, and the server recomputes the challenge from it
        let first = PKCEChallenge(verifier: "a-fixed-verifier-value-for-this-test-abcdefgh")
        let second = PKCEChallenge(verifier: "a-fixed-verifier-value-for-this-test-abcdefgh")

        #expect(first.challenge == second.challenge)
    }

    // MARK: - State

    @Test func matchingStateIsAccepted() {
        let state = OAuthState.make()

        #expect(OAuthState.matches(state, state))
    }

    @Test func aDifferentStateIsRejected() {
        #expect(!OAuthState.matches(OAuthState.make(), OAuthState.make()))
    }

    @Test func aStateOfTheWrongLengthIsRejected() {
        // A prefix of the real state must not pass
        let state = OAuthState.make()
        let truncated = String(state.dropLast())

        #expect(!OAuthState.matches(truncated, state))
    }

    @Test func everyStateIsDifferent() {
        let states = Set((0..<50).map { _ in OAuthState.make() })

        #expect(states.count == 50)
    }

    // MARK: - Form Encoding

    @Test func formEncodingEscapesTheCharactersThatWouldSplitABody() {
        // A token containing any of these would otherwise be read as several fields
        #expect("a+b".addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) == "a%2Bb")
        #expect("a&b".addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) == "a%26b")
        #expect("a=b".addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) == "a%3Db")
        #expect("a/b".addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) == "a%2Fb")
    }

    @Test func formEncodingLeavesTheUnreservedCharactersAlone() {
        // RFC 3986 unreserved set: these never need escaping, and escaping them would be wrong
        let unreserved = "abcXYZ019-._~"

        #expect(unreserved.addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) == unreserved)
    }

    @Test func aBase64TokenSurvivesFormEncoding() {
        // This is the bug that was there before. A refresh token is usually base64, so it often
        // contains + / and =, and the old `.urlQueryAllowed` left all three untouched: the + came
        // back out as a space and the = split the field. The token arrived at the server wrong.
        let token = "abc+def/ghi=="

        let encoded = token.addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed)

        #expect(encoded == "abc%2Bdef%2Fghi%3D%3D")
        #expect(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) == token,
                "the old character set left it unescaped, which is what made this a bug")
    }

    @Test func aSpaceSeparatedScopeIsStillEncodedTheSameWay() {
        // OneDrive sends its scopes space-separated in the form body. Both the old and the new
        // character set escape a space as %20, so this behaviour is unchanged by the fix
        let scope = "Files.ReadWrite offline_access"

        #expect(scope.addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) == "Files.ReadWrite%20offline_access")
    }
}
