//
//  GmailBatchProtocol.swift
//  SwiftGmail
//
//  Pure multipart/mixed encode + decode for Gmail's `/batch/gmail/v1`
//  endpoint. No networking, no state — every function here is a total
//  function over bytes, so the wire format is unit-testable without a
//  live account. `GmailAPIClient` owns the HTTP and the retry policy.
//
//  Wire format (RFC 2046 multipart + RFC 7230 "application/http"):
//
//      --BOUNDARY
//      Content-Type: application/http
//      Content-ID: <op-0>
//
//      GET /gmail/v1/users/me/messages/ID?format=full
//
//      --BOUNDARY--
//
//  The response mirrors it, each part carrying `Content-ID: <response-op-0>`
//  and a complete HTTP response (status line, headers, blank line, body).
//

import Foundation
import os

private let logger = GmailLogging.logger(category: "GmailBatchProtocol")

// MARK: - Request

/// One sub-request inside a batch. `contentId` is OUR correlation key —
/// index-derived, not the Gmail id, so a resource id containing a character
/// that is illegal in a MIME `Content-ID` can never corrupt the envelope.
struct GmailBatchOperation: Sendable, Equatable {
    let contentId: String
    /// Origin-relative request target, e.g. `/gmail/v1/users/me/messages/abc?format=full`.
    let path: String
}

/// One decoded sub-response.
struct GmailBatchPart: Sendable, Equatable {
    /// The `contentId` of the request this answers, recovered from the part's
    /// `Content-ID: <response-…>` header. `nil` when the server omitted it —
    /// the parser then falls back to positional matching (the batch spec
    /// guarantees order only as a courtesy, so we prefer the header).
    let contentId: String?
    let statusCode: Int
    let body: Data
}

/// Raised when the batch envelope itself is rejected (400/415) or is
/// unparseable — the caller falls back to per-id requests.
struct GmailBatchUnsupported: Error, Sendable {
    let reason: String
}

public enum GmailBatchProtocol {

    /// Gmail's hard cap on sub-requests per batch.
    static let maxOperationsPerBatch = 100

    /// Operations per batch, sized by how big the sub-responses can get.
    ///
    /// `format=full`/`raw` inline attachment bytes as base64 inside the message
    /// payload, so a single sub-response can be tens of megabytes. The whole
    /// envelope is buffered in memory before it can be parsed, so a 50-wide
    /// `.full` batch (times the in-flight count) is a real peak-memory risk —
    /// worse than the 5-concurrent path this replaced. Header-only formats have
    /// no such tail and get the wider batch.
    public static func maxOperations(for format: MessageFormat) -> Int {
        switch format {
        case .full, .raw: return 20
        case .metadata, .minimal: return 50
        }
    }

    /// Operations per batch for a call on `lane` that costs `unitCost` a part.
    ///
    /// On the BULK lane an envelope is also capped at
    /// `GmailQuotaBucket.bulkEnvelopeUnits` of quota (t-a9825f81). An envelope
    /// spends its whole cost in one instant, and the per-user budget is shared
    /// by every device on the account, so the lump matters as much as the
    /// average: a 50-part `.metadata` envelope is 1,000 units, and three
    /// devices each landing two of them in one minute is the entire 6,000.
    /// Interactive calls keep the format's full width — they are short, and
    /// fewer round trips is what a waiting person needs.
    static func maxOperations(
        for format: MessageFormat,
        unitCost: Int,
        lane: GmailQuotaLane
    ) -> Int {
        let byFormat = maxOperations(for: format)
        guard lane == .bulk, unitCost > 0 else { return byFormat }
        return min(byFormat, max(1, GmailQuotaBucket.bulkEnvelopeUnits / unitCost))
    }

    /// Concurrent envelopes in flight — enough to hide round-trip latency
    /// without multiplying the buffered-response footprint above.
    public static func maxBatchesInFlight(for format: MessageFormat) -> Int {
        switch format {
        case .full, .raw: return 2
        case .metadata, .minimal: return 3
        }
    }

    /// A boundary that cannot occur inside a JSON body or a header.
    static func makeBoundary() -> String {
        "batch_poxt_\(UUID().uuidString)"
    }

    static func contentId(forIndex index: Int) -> String {
        "op-\(index)"
    }

    /// Encode the multipart request body. Always CRLF — the spec requires it,
    /// and Google's parser is not lenient about the request direction.
    static func encodeRequest(operations: [GmailBatchOperation], boundary: String) -> Data {
        var text = ""
        for operation in operations {
            text += "--\(boundary)\r\n"
            text += "Content-Type: application/http\r\n"
            text += "Content-ID: <\(operation.contentId)>\r\n"
            text += "\r\n"
            text += "GET \(operation.path)\r\n"
            text += "\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    // MARK: - Response

    /// Pull the `boundary=` parameter out of a `multipart/mixed` Content-Type.
    /// Tolerates quoting and surrounding whitespace.
    static func boundary(fromContentType contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Decode a multipart/mixed batch response into its parts, in wire order.
    /// Tolerant of CRLF and bare-LF line endings (Google emits CRLF, but a
    /// proxy that rewrites them must not break sync).
    static func decodeResponse(data: Data, boundary: String) throws -> [GmailBatchPart] {
        let delimiter = Data("--\(boundary)".utf8)
        let markers = ranges(of: delimiter, in: data)
        guard !markers.isEmpty else {
            throw GmailBatchUnsupported(reason: "no multipart boundary in response")
        }

        var parts: [GmailBatchPart] = []
        var unreadable = 0
        for (offset, marker) in markers.enumerated() {
            // `--BOUNDARY--` closes the multipart; anything after is epilogue.
            if isClosingDelimiter(in: data, after: marker.upperBound) { break }
            let end = offset + 1 < markers.count ? markers[offset + 1].lowerBound : data.endIndex
            guard marker.upperBound <= end else { continue }
            let raw = data[marker.upperBound..<end]
            if let part = decodePart(raw) {
                parts.append(part)
            } else {
                // A part we couldn't frame is a sub-response the caller will
                // never see. Silently dropping it made a malformed envelope
                // look like a short one; the count is the breadcrumb.
                unreadable += 1
            }
        }

        if unreadable > 0 {
            logger.warning("Gmail batch response: \(unreadable, privacy: .public) of \(unreadable + parts.count, privacy: .public) part(s) were unparseable and dropped")
        }

        guard !parts.isEmpty else {
            throw GmailBatchUnsupported(reason: "multipart response contained no readable parts")
        }
        return parts
    }

    // MARK: - Part decoding

    private static func decodePart(_ raw: Data) -> GmailBatchPart? {
        // raw = [CR]LF <part headers> blank-line <embedded HTTP response> [CR]LF
        guard let headerSplit = blankLineRange(in: raw, from: raw.startIndex) else { return nil }
        let partHeaders = string(raw[raw.startIndex..<headerSplit.lowerBound])
        let embedded = raw[headerSplit.upperBound...]

        // The embedded HTTP response: status line + headers, blank line, body.
        guard let statusLineEnd = lineEnd(in: embedded, from: embedded.startIndex) else { return nil }
        let statusLine = string(embedded[embedded.startIndex..<statusLineEnd.lowerBound])
        guard let statusCode = statusCode(fromStatusLine: statusLine) else { return nil }

        var body = Data()
        if let bodySplit = blankLineRange(in: embedded, from: statusLineEnd.lowerBound) {
            body = Data(embedded[bodySplit.upperBound...])
            // Strip the CRLF the multipart framing appends before the next delimiter.
            body = trimmingTrailingNewline(body)
        }

        return GmailBatchPart(
            contentId: contentId(fromHeaders: partHeaders),
            statusCode: statusCode,
            body: body
        )
    }

    /// `HTTP/1.1 404 Not Found` → 404.
    private static func statusCode(fromStatusLine line: String) -> Int? {
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count >= 2, fields[0].uppercased().hasPrefix("HTTP/") else { return nil }
        return Int(fields[1])
    }

    /// `Content-ID: <response-op-3>` → `op-3`.
    private static func contentId(fromHeaders headers: String) -> String? {
        for line in headers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-id"
            else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("response-") {
                value = String(value.dropFirst("response-".count))
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Byte scanning
    //
    // Everything below works on bytes, not String: a `metadata` body is UTF-8
    // JSON, but a `raw`/`full` body can carry bytes that would be lossy or
    // length-shifting through a String round trip, and the framing offsets
    // must stay exact.

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let dash: UInt8 = 0x2D

    private static func string(_ slice: Data) -> String {
        String(decoding: slice, as: UTF8.self)
    }

    private static func ranges(of needle: Data, in haystack: Data) -> [Range<Data.Index>] {
        var found: [Range<Data.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, in: searchStart..<haystack.endIndex) {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// True when the bytes right after a delimiter are `--` (the closing one).
    private static func isClosingDelimiter(in data: Data, after index: Data.Index) -> Bool {
        let next = data.index(after: index)
        guard next < data.endIndex else { return false }
        return data[index] == dash && data[next] == dash
    }

    /// Range covering the line terminator that ends the line starting at `from`.
    private static func lineEnd(in data: Data, from start: Data.Index) -> Range<Data.Index>? {
        var index = start
        while index < data.endIndex {
            if data[index] == lf {
                return index..<data.index(after: index)
            }
            if data[index] == cr {
                let next = data.index(after: index)
                if next < data.endIndex, data[next] == lf {
                    return index..<data.index(after: next)
                }
                return index..<next
            }
            index = data.index(after: index)
        }
        return nil
    }

    /// Range covering the first blank line at or after `start` — i.e. the
    /// header/body separator. Handles CRLFCRLF, LFLF, and the mixed forms.
    private static func blankLineRange(in data: Data, from start: Data.Index) -> Range<Data.Index>? {
        var index = start
        while index < data.endIndex {
            guard let terminator = lineEnd(in: data, from: index) else { return nil }
            if let next = lineEnd(in: data, from: terminator.upperBound),
               next.lowerBound == terminator.upperBound {
                // Two terminators back to back → blank line.
                return terminator.lowerBound..<next.upperBound
            }
            index = terminator.upperBound
        }
        return nil
    }

    private static func trimmingTrailingNewline(_ data: Data) -> Data {
        var end = data.endIndex
        if end > data.startIndex, data[data.index(before: end)] == lf {
            end = data.index(before: end)
            if end > data.startIndex, data[data.index(before: end)] == cr {
                end = data.index(before: end)
            }
        }
        return Data(data[data.startIndex..<end])
    }
}
