import Foundation
import Testing
@testable import SwiftGmail

/// `GmailMessage` address-header extraction.
///
/// The draft-sync tests inject Bcc through the `FetchedDraft` test double, so
/// they never exercise `GmailMessage.bccAddresses` — the one piece of the Bcc
/// round-trip (t-860210b2) that actually parses the fetched payload. These pin
/// that a `Bcc:` header on a `format=full` payload is surfaced (case-
/// insensitively), that an absent header is `nil` (which `syncDrafts` maps to
/// `""` → "the draft has no Bcc"), and that To/Cc/Bcc extract independently.
///
/// NOTE: this verifies OUR parsing, not Gmail's behavior. Whether Gmail returns
/// the `Bcc:` header for an owned draft at `format=full` is a live-API fact
/// confirmed by dogfood; if it ever stops, these still pass but the round-trip
/// silently no-ops — so the dogfood check remains the backstop.
@Suite("GmailMessage — header extraction")
struct GmailMessageHeaderTests {

    /// Decode a minimal Gmail `messages.get` payload carrying the given headers
    /// (exercises the real Codable path, not a memberwise init).
    private static func decode(headers: [(String, String)]) throws -> GmailMessage {
        let headerObjs = headers
            .map { "{\"name\":\"\($0.0)\",\"value\":\"\($0.1)\"}" }
            .joined(separator: ",")
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["DRAFT"],"snippet":"",\
        "internalDate":"1700000000000","payload":{"headers":[\(headerObjs)]}}
        """
        return try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    @Test("Bcc header is surfaced via bccAddresses (the piece the FetchedDraft double bypasses)")
    func bccHeaderSurfaced() throws {
        let msg = try Self.decode(headers: [("Bcc", "secret@example.com, second@example.com")])
        #expect(msg.bccAddresses == "secret@example.com, second@example.com")
    }

    @Test("Bcc lookup is case-insensitive")
    func bccCaseInsensitive() throws {
        let msg = try Self.decode(headers: [("bcc", "lower@example.com")])
        #expect(msg.bccAddresses == "lower@example.com")
    }

    @Test("Absent Bcc header yields nil (syncDrafts maps that to \"\")")
    func bccAbsentIsNil() throws {
        let msg = try Self.decode(headers: [("To", "a@example.com")])
        #expect(msg.bccAddresses == nil)
    }

    @Test("To / Cc / Bcc extract independently from one payload")
    func addressHeaderParity() throws {
        let msg = try Self.decode(headers: [
            ("To", "to@example.com"), ("Cc", "cc@example.com"), ("Bcc", "bcc@example.com")
        ])
        #expect(msg.toAddresses == "to@example.com")
        #expect(msg.ccAddresses == "cc@example.com")
        #expect(msg.bccAddresses == "bcc@example.com")
    }
}
