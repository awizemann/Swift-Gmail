import Foundation
import Testing
@testable import SwiftGmail

/// The `/batch/gmail/v1` wire format (t-b16fa26a). Everything here is byte-level:
/// a batch that mis-frames one part silently drops real mail, and the failure is
/// invisible at every other seam (the sync just reports fewer messages).
@Suite("Gmail batch multipart protocol")
struct GmailBatchProtocolTests {

    // MARK: - Request building

    @Test("Request body frames one application/http GET per operation, CRLF throughout")
    func encodesRequest() throws {
        let body = GmailBatchProtocol.encodeRequest(
            operations: [
                GmailBatchOperation(contentId: "op-0", path: "/gmail/v1/users/me/messages/abc?format=full"),
                GmailBatchOperation(contentId: "op-1", path: "/gmail/v1/users/me/messages/def?format=metadata")
            ],
            boundary: "BOUND"
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.hasPrefix("--BOUND\r\n"))
        #expect(text.hasSuffix("--BOUND--\r\n"))
        #expect(text.contains("Content-Type: application/http\r\n"))
        #expect(text.contains("Content-ID: <op-0>\r\n"))
        #expect(text.contains("Content-ID: <op-1>\r\n"))
        #expect(text.contains("GET /gmail/v1/users/me/messages/abc?format=full\r\n"))
        // The format param is passed straight through, per operation.
        #expect(text.contains("GET /gmail/v1/users/me/messages/def?format=metadata\r\n"))
        // Exactly two opening delimiters + one closing.
        #expect(text.components(separatedBy: "--BOUND").count == 4)
        #expect(!text.contains("\n\n"), "a bare LF would break Google's request parser")
    }

    @Test("An empty operation list still produces a well-formed (closed) envelope")
    func encodesEmptyRequest() {
        let body = GmailBatchProtocol.encodeRequest(operations: [], boundary: "B")
        #expect(String(decoding: body, as: UTF8.self) == "--B--\r\n")
    }

    // MARK: - Content-Type boundary extraction

    @Test(
        "Boundary is read off the response Content-Type, quoted or bare",
        arguments: [
            ("multipart/mixed; boundary=batch_abc", "batch_abc"),
            ("multipart/mixed; boundary=\"batch_abc\"", "batch_abc"),
            ("multipart/mixed;boundary=batch_abc", "batch_abc"),
            ("multipart/mixed; charset=utf-8; boundary= batch_abc", "batch_abc")
        ]
    )
    func extractsBoundary(contentType: String, expected: String) {
        #expect(GmailBatchProtocol.boundary(fromContentType: contentType) == expected)
    }

    @Test("A non-multipart Content-Type yields no boundary (caller falls back)")
    func rejectsNonMultipartContentType() {
        #expect(GmailBatchProtocol.boundary(fromContentType: "application/json") == nil)
        #expect(GmailBatchProtocol.boundary(fromContentType: "multipart/mixed") == nil)
    }

    // MARK: - Response parsing

    private static let okBody = #"{"id":"m1","threadId":"t1","snippet":"hi","internalDate":"1700000000000"}"#

    /// A realistic mixed response: one success, one 404 (message deleted between
    /// list and get), one 429 (per-part rate limit). The single newline before
    /// each delimiter is the multipart framing one — the parser must strip that
    /// and nothing else. `newline` lets the same fixture be replayed with bare LF.
    private static func mixedResponse(boundary: String, newline: String) -> Data {
        let lines = [
            "--\(boundary)",
            "Content-Type: application/http",
            "Content-ID: <response-op-0>",
            "",
            "HTTP/1.1 200 OK",
            "Content-Type: application/json; charset=UTF-8",
            "",
            okBody,
            "--\(boundary)",
            "Content-Type: application/http",
            "Content-ID: <response-op-1>",
            "",
            "HTTP/1.1 404 Not Found",
            "Content-Type: application/json; charset=UTF-8",
            "",
            #"{"error":{"code":404}}"#,
            "--\(boundary)",
            "Content-Type: application/http",
            "Content-ID: <response-op-2>",
            "",
            "HTTP/1.1 429 Too Many Requests",
            "Content-Type: application/json; charset=UTF-8",
            "",
            #"{"error":{"code":429}}"#,
            "--\(boundary)--",
            ""
        ]
        return Data(lines.joined(separator: newline).utf8)
    }

    @Test("Mixed 200/404/429 parts decode with their status codes and Content-IDs (CRLF)")
    func parsesMixedPartsCRLF() throws {
        let parts = try GmailBatchProtocol.decodeResponse(
            data: Self.mixedResponse(boundary: "batch_x", newline: "\r\n"),
            boundary: "batch_x"
        )

        #expect(parts.count == 3)
        #expect(parts.map(\.statusCode) == [200, 404, 429])
        #expect(parts.map(\.contentId) == ["op-0", "op-1", "op-2"])
        // `response-` prefix and angle brackets are stripped so the id matches
        // the one we sent.
        #expect(String(decoding: parts[0].body, as: UTF8.self) == Self.okBody)
        #expect(String(decoding: parts[1].body, as: UTF8.self) == #"{"error":{"code":404}}"#)
    }

    @Test("The same response with bare LF line endings parses identically")
    func parsesMixedPartsLF() throws {
        let crlf = try GmailBatchProtocol.decodeResponse(
            data: Self.mixedResponse(boundary: "batch_x", newline: "\r\n"),
            boundary: "batch_x"
        )
        let lf = try GmailBatchProtocol.decodeResponse(
            data: Self.mixedResponse(boundary: "batch_x", newline: "\n"),
            boundary: "batch_x"
        )
        #expect(crlf == lf)
    }

    @Test("A decoded 200 body round-trips through JSONDecoder into a GmailMessage")
    func bodyIsDecodable() throws {
        let parts = try GmailBatchProtocol.decodeResponse(
            data: Self.mixedResponse(boundary: "batch_x", newline: "\r\n"),
            boundary: "batch_x"
        )
        let message = try JSONDecoder().decode(GmailMessage.self, from: parts[0].body)
        #expect(message.id == "m1")
        #expect(message.threadId == "t1")
    }

    @Test("Preamble and epilogue around the multipart are ignored")
    func ignoresPreambleAndEpilogue() throws {
        var data = Data("This is a multipart message.\r\n".utf8)
        data.append(Self.mixedResponse(boundary: "b", newline: "\r\n"))
        data.append(Data("trailing junk\r\n".utf8))

        let parts = try GmailBatchProtocol.decodeResponse(data: data, boundary: "b")
        #expect(parts.count == 3)
        #expect(parts.map(\.statusCode) == [200, 404, 429])
    }

    @Test("A part with no Content-ID still parses (caller matches positionally)")
    func toleratesMissingContentID() throws {
        let raw = [
            "--b",
            "Content-Type: application/http",
            "",
            "HTTP/1.1 200 OK",
            "",
            #"{"id":"m9"}"#,
            "--b--",
            ""
        ].joined(separator: "\r\n")

        let parts = try GmailBatchProtocol.decodeResponse(data: Data(raw.utf8), boundary: "b")
        #expect(parts.count == 1)
        #expect(parts[0].contentId == nil)
        #expect(parts[0].statusCode == 200)
        #expect(String(decoding: parts[0].body, as: UTF8.self) == #"{"id":"m9"}"#)
    }

    @Test("A body containing a blank line is not truncated at it")
    func preservesBlankLinesInsideBody() throws {
        let raw = [
            "--b",
            "Content-Type: application/http",
            "Content-ID: <response-op-0>",
            "",
            "HTTP/1.1 200 OK",
            "Content-Type: text/plain",
            "",
            "line one",
            "",
            "line three",
            "--b--",
            ""
        ].joined(separator: "\r\n")

        let parts = try GmailBatchProtocol.decodeResponse(data: Data(raw.utf8), boundary: "b")
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "line one\r\n\r\nline three")
    }

    @Test("A response with no boundary at all is reported unsupported, not silently empty")
    func rejectsNonMultipartBody() {
        #expect(throws: GmailBatchUnsupported.self) {
            _ = try GmailBatchProtocol.decodeResponse(
                data: Data(#"{"error":{"code":400}}"#.utf8),
                boundary: "b"
            )
        }
    }

    @Test("A multipart containing only the closing delimiter is unsupported, not an empty success")
    func rejectsEmptyMultipart() {
        #expect(throws: GmailBatchUnsupported.self) {
            _ = try GmailBatchProtocol.decodeResponse(data: Data("--b--\r\n".utf8), boundary: "b")
        }
    }

    // MARK: - Correlation keys

    @Test("Content-IDs are index-derived, so a resource id can never corrupt the envelope")
    func contentIdsAreIndexDerived() {
        #expect(GmailBatchProtocol.contentId(forIndex: 0) == "op-0")
        #expect(GmailBatchProtocol.contentId(forIndex: 49) == "op-49")
    }

    @Test("Boundaries are unique per envelope")
    func boundariesAreUnique() {
        #expect(GmailBatchProtocol.makeBoundary() != GmailBatchProtocol.makeBoundary())
    }

    @Test("Every batch size stays inside Gmail's 100-operation cap")
    func batchSizeWithinCap() {
        #expect(GmailBatchProtocol.maxOperationsPerBatch == 100)
        for format in [MessageFormat.full, .raw, .metadata, .minimal] {
            #expect(GmailBatchProtocol.maxOperations(for: format) <= GmailBatchProtocol.maxOperationsPerBatch)
            #expect(GmailBatchProtocol.maxOperations(for: format) > 0)
        }
    }

    /// `format=full` inlines attachment bytes as base64, so the whole buffered
    /// envelope can be tens of MB per sub-response. Body formats must batch
    /// narrower AND run fewer envelopes concurrently than header-only ones, or
    /// batching trades round trips for a memory spike.
    @Test("Body-bearing formats batch narrower and less concurrently than header-only ones")
    func bodyFormatsAreThrottled() {
        for body in [MessageFormat.full, .raw] {
            for headersOnly in [MessageFormat.metadata, .minimal] {
                #expect(GmailBatchProtocol.maxOperations(for: body)
                        < GmailBatchProtocol.maxOperations(for: headersOnly))
                #expect(GmailBatchProtocol.maxBatchesInFlight(for: body)
                        < GmailBatchProtocol.maxBatchesInFlight(for: headersOnly))
            }
        }
    }
}
