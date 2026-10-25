import Foundation
import Testing
@testable import SwiftGmail

/// The `+`-as-space Gmail query bug (2026-08-13). `URLComponents` leaves a
/// literal `+` unescaped in query values; Gmail's server form-decodes `+` as
/// a space, so a `rfc822msgid:` search for a Gmail-composed Message-ID
/// (`CAL…+=…@mail.gmail.com`) silently matched nothing and every attachment
/// download on such a message failed. `apiURL` must emit `%2B`.
@Suite("GmailAPIClient URL encoding")
struct GmailAPIClientURLTests {

    @Test("A + in a query value is percent-encoded, never left to decode as a space")
    func plusSurvivesTheRoundTrip() throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let url = try client.apiURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages",
            queryItems: [
                URLQueryItem(name: "q", value: "rfc822msgid:CALcfcgCvvhZso+=VKZefteck-wyV1kZ@mail.gmail.com"),
                URLQueryItem(name: "maxResults", value: "1"),
            ]
        )
        let query = try #require(url.query(percentEncoded: true))
        #expect(!query.contains("+"), "a literal + reaches Gmail as a space")
        #expect(query.contains("CALcfcgCvvhZso%2B"))
        // The value-internal '=' is fine un-encoded (Gmail splits on the
        // FIRST '=' only — 155 ready rows with '=' ids prove it in the
        // field), and the real name/value separators must stay intact.
        #expect(query.contains("q=rfc822msgid"))
        #expect(query.contains("maxResults=1"))

        // The reconstructed request decodes back to the ORIGINAL id.
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try #require(components.queryItems?.first(where: { $0.name == "q" })?.value)
        #expect(q == "rfc822msgid:CALcfcgCvvhZso+=VKZefteck-wyV1kZ@mail.gmail.com")
    }
}

@Suite("GmailAPIClient listDrafts query")
struct GmailAPIClientListDraftsQueryTests {

    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: URL?
        var url: URL? { lock.withLock { _url } }
        func record(_ url: URL?) { lock.withLock { _url = url } }
    }

    static func client(capturing captured: Captured) -> GmailAPIClient {
        GmailAPIClient(quotaBucket: GmailQuotaBucket(), transport: { request in
            captured.record(request.url)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"drafts":[{"id":"r1","message":{"id":"m1","threadId":"t1"}}]}"#.utf8), response)
        })
    }

    @Test("query and includeSpamTrash reach drafts.list, with + encoded")
    func queryIsSent() async throws {
        let captured = Captured()
        let response = try await Self.client(capturing: captured).listDrafts(
            accessToken: "t", query: "rfc822msgid:CAL+x=y@mail.gmail.com", includeSpamTrash: true
        )
        #expect(response.drafts?.first?.id == "r1")
        let url = try #require(captured.url)
        let raw = try #require(url.query(percentEncoded: true))
        #expect(!raw.contains("+"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "q" }?.value == "rfc822msgid:CAL+x=y@mail.gmail.com")
        #expect(items.first { $0.name == "includeSpamTrash" }?.value == "true")
    }

    @Test("Without a query, drafts.list sends no q and no includeSpamTrash")
    func noQueryByDefault() async throws {
        let captured = Captured()
        _ = try await Self.client(capturing: captured).listDrafts(accessToken: "t")
        let url = try #require(captured.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["maxResults"])
    }
}
