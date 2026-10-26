import Foundation
import os
import Testing
@testable import SwiftGmail

/// The 0.3.5 additions, end to end through the injected `Transport` and a
/// virtual-clock bucket: path encoding, the base URL override, lenient
/// decoding, the new endpoints and their retry rules, and the public
/// token-source variants.
@Suite("GmailAPIClient — 0.3.5 additions")
struct GmailAPIClientAdditionsTests {

    /// Clock the bucket's sleeper advances; nothing sleeps for real.
    private final class VirtualClock: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        var now: Date { state.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
        func bucket() -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] in advance($0) })
        }
    }

    /// Answers request n with `steps[n]` (the last repeats) and records every
    /// request it saw.
    private final class Recorder: @unchecked Sendable {
        enum Step { case http(Int, String, [String: String] = [:]), fail(URLError.Code) }
        private let lock = NSLock()
        private let steps: [Step]
        private var seen: [URLRequest] = []
        init(_ steps: [Step]) { self.steps = steps }

        var requests: [URLRequest] { lock.withLock { seen } }
        var attempts: Int { requests.count }
        var last: URLRequest { requests.last! }

        func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            let step: Step = lock.withLock {
                seen.append(request)
                return steps[min(seen.count - 1, steps.count - 1)]
            }
            switch step {
            case .fail(let code):
                throw URLError(code)
            case .http(let status, let body, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                return (Data(body.utf8), response)
            }
        }
    }

    private static func client(_ recorder: Recorder, baseURL: URL? = nil) -> GmailAPIClient {
        let transport: GmailAPIClient.Transport = { try recorder.respond(to: $0) }
        if let baseURL {
            return GmailAPIClient(quotaBucket: VirtualClock().bucket(), transport: transport, baseURL: baseURL)
        }
        return GmailAPIClient(quotaBucket: VirtualClock().bucket(), transport: transport)
    }

    private static let sendOK = #"{"id":"m1","threadId":"t1","labelIds":["SENT"]}"#
    private static let messageOK = #"{"id":"m1","threadId":"t1","snippet":"","internalDate":"0"}"#
    private static let rate403 = """
        {"error":{"code":403,"message":"Rate Limit Exceeded",
          "errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}],"status":"PERMISSION_DENIED"}}
        """

    private static func items(_ request: URLRequest, _ name: String) -> [String] {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return (components?.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    // MARK: - Path encoding

    @Test("A Gmail hex id is unchanged; hostile ids stay inside one segment", arguments: [
        ("18c2f3a9b7d4e5f6", "18c2f3a9b7d4e5f6"),
        ("../x", "..%2Fx"),
        ("a/b?c#d", "a%2Fb%3Fc%23d"),
        ("100% sure", "100%25%20sure"),
        (".", "%2E"),
        ("..", "%2E%2E"),
        ("é+=", "%C3%A9%2B%3D"),
    ])
    func pathSegment(id: String, expected: String) {
        #expect(GmailAPIClient.pathSegment(id) == expected)
    }

    @Test("A hostile message id reaches the wire as one segment of /messages")
    func hostileIdOnTheWire() async throws {
        for id in ["../x", "a/b?c#d", ".."] {
            let recorder = Recorder([.http(200, Self.messageOK)])
            _ = try await Self.client(recorder).getMessage(accessToken: "t", messageId: id)
            let url = recorder.last.url!
            #expect(url.path(percentEncoded: false) == "/gmail/v1/users/me/messages/\(id)")
            #expect(url.standardized.path(percentEncoded: false) == "/gmail/v1/users/me/messages/\(id)")
            #expect(Self.items(recorder.last, "format") == ["full"], "nothing after ? or # leaked into the query")
            #expect(url.fragment == nil)
        }
    }

    @Test("Draft, thread and attachment ids are encoded too")
    func otherIdsEncoded() async throws {
        let recorder = Recorder([.http(200, #"{"id":"r1","messages":[],"size":1,"data":"QQ"}"#)])
        let client = Self.client(recorder)
        _ = try await client.getThread(accessToken: "t", threadId: "t/1")
        #expect(recorder.last.url!.absoluteString.hasSuffix("/threads/t%2F1?format=full"))
        _ = try await client.getAttachment(accessToken: "t", messageId: "m?1", attachmentId: "a#1")
        #expect(recorder.last.url!.absoluteString.hasSuffix("/messages/m%3F1/attachments/a%231"))
        try await client.deleteDraft(accessToken: "t", draftId: "..")
        #expect(recorder.last.url!.absoluteString.hasSuffix("/drafts/%2E%2E"))
    }

    // MARK: - Base URL

    @Test("A custom base URL roots REST calls and the batch envelope; sub-request paths stay relative")
    func customBaseURL() async throws {
        let root = try #require(URL(string: "https://proxy.example.com/gmail-proxy/"))
        let profile = Recorder([.http(200, #"{"emailAddress":"a@b.c","historyId":"1"}"#)])
        _ = try await Self.client(profile, baseURL: root).getProfile(accessToken: "t")
        #expect(profile.last.url!.absoluteString == "https://proxy.example.com/gmail-proxy/gmail/v1/users/me/profile")

        let boundary = "b"
        let reply = "--\(boundary)\r\nContent-Type: application/http\r\n"
            + "Content-ID: <response-\(GmailBatchProtocol.contentId(forIndex: 0))>\r\n\r\n"
            + "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(Self.messageOK)\r\n--\(boundary)--\r\n"
        let batch = Recorder([.http(200, reply, ["Content-Type": "multipart/mixed; boundary=\(boundary)"])])
        let outcome = try await Self.client(batch, baseURL: root).getMessagesOutcome(
            tokenSource: .fixed("t"), messageIds: ["a/b"], quotaKey: "k"
        )
        #expect(outcome.fetched.map(\.id) == ["m1"])
        #expect(batch.last.url!.absoluteString == "https://proxy.example.com/gmail-proxy/batch/gmail/v1")
        #expect(batch.last.httpMethod == "POST")
        let body = String(decoding: try #require(batch.last.httpBody), as: UTF8.self)
        #expect(body.contains("GET /gmail/v1/users/me/messages/a%2Fb?format=full\r\n"))
    }

    @Test("The default base URL is Google's")
    func defaultBaseURL() async throws {
        let recorder = Recorder([.http(200, #"{"labels":[]}"#)])
        _ = try await Self.client(recorder).listLabels(accessToken: "t")
        #expect(recorder.last.url!.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels")
    }

    // MARK: - Lenient decoding

    @Test("A message without snippet, and a body without size, decode as \"\" and 0, and round-trip")
    func lenientDecoding() throws {
        let json = """
            {"id":"18c2f3","threadId":"18c2f0","labelIds":["INBOX"],"historyId":"42","internalDate":"1700000000000",
             "sizeEstimate":512,
             "payload":{"partId":"","mimeType":"multipart/mixed","filename":"",
               "headers":[{"name":"Subject","value":"Hi"}],"body":{},
               "parts":[{"partId":"0","mimeType":"text/plain","filename":"","body":{"data":"SGk"}},
                        {"partId":"1","mimeType":"application/pdf","filename":"a.pdf","body":{"attachmentId":"ANG"}}]}}
            """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        #expect(message.snippet == "")
        #expect(message.payload?.body?.size == 0)
        #expect(message.payload?.parts?[0].body?.size == 0)
        #expect(message.payload?.parts?[1].body?.attachmentId == "ANG")
        #expect(message.subject == "Hi")
        #expect(message.sizeEstimate == 512)

        let again = try JSONDecoder().decode(GmailMessage.self, from: JSONEncoder().encode(message))
        #expect(again.id == message.id && again.snippet == "" && again.payload?.parts?[0].body?.data == "SGk")
    }

    @Test("threadId and internalDate stay required")
    func strictFieldsStayStrict() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GmailMessage.self, from: Data(#"{"id":"m","threadId":"t"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GmailMessage.self, from: Data(#"{"id":"m","internalDate":"0"}"#.utf8))
        }
    }

    // MARK: - drafts.send

    @Test("sendDraft POSTs {\"id\"} to drafts/send and decodes the sent message")
    func sendDraftRequest() async throws {
        let recorder = Recorder([.http(200, Self.sendOK)])
        let sent = try await Self.client(recorder).sendDraft(accessToken: "tok", draftId: "r-1")
        #expect(sent.id == "m1" && sent.labelIds == ["SENT"])
        #expect(recorder.last.httpMethod == "POST")
        #expect(recorder.last.url!.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/drafts/send")
        #expect(recorder.last.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(try Self.jsonBody(recorder.last) == ["id": "r-1"])
    }

    @Test("sendDraft: a 500 or a timeout is one attempt — it may have been sent")
    func sendDraftNotRetried() async throws {
        let server = Recorder([.http(500, "{}"), .http(200, Self.sendOK)])
        do {
            _ = try await Self.client(server).sendDraft(accessToken: "t", draftId: "r1")
            Issue.record("expected a throw")
        } catch {
            #expect(GmailAPIError.isAmbiguousDelivery(error))
        }
        #expect(server.attempts == 1)

        let timeout = Recorder([.fail(.timedOut), .http(200, Self.sendOK)])
        await #expect(throws: URLError.self) {
            _ = try await Self.client(timeout).sendDraft(accessToken: "t", draftId: "r1")
        }
        #expect(timeout.attempts == 1)
    }

    @Test("sendDraft: a 429 and a rate-limit 403 are retried", arguments: [429, 403])
    func sendDraftRateRetried(status: Int) async throws {
        let recorder = Recorder([.http(status, status == 403 ? Self.rate403 : "{}"), .http(200, Self.sendOK)])
        let sent = try await Self.client(recorder).sendDraft(accessToken: "t", draftId: "r1")
        #expect(sent.id == "m1")
        #expect(recorder.attempts == 2)
    }

    @Test("sendDraft is charged drafts.send's units, not messages.send's or drafts.create's")
    func sendDraftCharge() async throws {
        let d = GmailUnitCost.documented
        let cost = GmailUnitCost(
            getProfile: d.getProfile, labelsList: d.labelsList, historyList: d.historyList,
            messagesList: d.messagesList, messagesGet: d.messagesGet, messagesModify: d.messagesModify,
            messagesTrash: d.messagesTrash, messagesUntrash: d.messagesUntrash,
            messagesDelete: d.messagesDelete, messagesBatchModify: d.messagesBatchModify,
            messagesSend: 100, attachmentsGet: d.attachmentsGet, threadsList: d.threadsList,
            threadsGet: d.threadsGet, draftsList: d.draftsList, draftsCreate: 10,
            draftsUpdate: d.draftsUpdate, draftsDelete: d.draftsDelete,
            draftsGet: d.draftsGet, draftsSend: 77, labelsCreate: d.labelsCreate, labelsGet: d.labelsGet
        )
        let clock = VirtualClock()
        let start = clock.now
        let bucket = GmailQuotaBucket(
            now: { clock.now }, sleeper: { clock.advance($0) },
            profile: GmailQuotaProfile(unitsPerSecond: 10, perUserUnitsPerSecond: 10, unitCost: cost)
        )
        let recorder = Recorder([.http(200, Self.sendOK)])
        let client = GmailAPIClient(quotaBucket: bucket, transport: { try recorder.respond(to: $0) })
        _ = try await client.sendDraft(accessToken: "t", draftId: "r1", quotaKey: "k")
        // A fresh bucket's interactive clock moves by units / rate: 77 / 10 u/s.
        let pushed = try #require(await bucket.buckets["k"]?.nextFreeInteractive)
        #expect(abs(pushed.timeIntervalSince(start) - 7.7) < 0.001, "charged \(pushed.timeIntervalSince(start) * 10) units")
        #expect(GmailUnitCost.documented.draftsSend == 100)
    }

    @Test("sendDraft is unparkable: it does not wait out a cooldown")
    func sendDraftUnparkable() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        let recorder = Recorder([.http(200, Self.sendOK)])
        let client = GmailAPIClient(quotaBucket: bucket, transport: { try recorder.respond(to: $0) })
        await bucket.noteRateLimited(key: "k", retryAfter: 600)
        let start = clock.now
        _ = try await client.sendDraft(accessToken: "t", draftId: "r1", quotaKey: "k")
        #expect(clock.now.timeIntervalSince(start) < 60, "a send must not wait out a cooldown")
    }

    // MARK: - labels.create

    @Test("createLabel POSTs the name and visibilities to labels")
    func createLabelRequest() async throws {
        let recorder = Recorder([.http(200, #"{"id":"Label_7","name":"Work/Clients","type":"user"}"#)])
        let label = try await Self.client(recorder).createLabel(
            accessToken: "t", name: "Work/Clients", labelListVisibility: "labelShow", messageListVisibility: "hide"
        )
        #expect(label.id == "Label_7" && label.parentPath == "Work")
        #expect(recorder.last.httpMethod == "POST")
        #expect(recorder.last.url!.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        #expect(try Self.jsonBody(recorder.last) == [
            "name": "Work/Clients", "labelListVisibility": "labelShow", "messageListVisibility": "hide",
        ])

        let bare = Recorder([.http(200, #"{"id":"Label_8","name":"x"}"#)])
        _ = try await Self.client(bare).createLabel(accessToken: "t", name: "x")
        #expect(try Self.jsonBody(bare.last) == ["name": "x"])
    }

    @Test("createLabel: a 500 or a timeout is one attempt — a retry could duplicate")
    func createLabelNotRetried() async throws {
        let server = Recorder([.http(500, "{}"), .http(200, #"{"id":"L","name":"x"}"#)])
        await #expect(throws: GmailAPIError.httpError(statusCode: 500)) {
            _ = try await Self.client(server).createLabel(accessToken: "t", name: "x")
        }
        #expect(server.attempts == 1)

        let timeout = Recorder([.fail(.timedOut), .http(200, #"{"id":"L","name":"x"}"#)])
        await #expect(throws: URLError.self) {
            _ = try await Self.client(timeout).createLabel(accessToken: "t", name: "x")
        }
        #expect(timeout.attempts == 1)
    }

    @Test("createLabel: a 429 and a rate-limit 403 are retried", arguments: [429, 403])
    func createLabelRateRetried(status: Int) async throws {
        let recorder = Recorder([.http(status, status == 403 ? Self.rate403 : "{}"), .http(200, #"{"id":"L","name":"x"}"#)])
        let label = try await Self.client(recorder).createLabel(accessToken: "t", name: "x")
        #expect(label.id == "L")
        #expect(recorder.attempts == 2)
    }

    // MARK: - drafts.get

    @Test("getDraft GETs drafts/{id}?format= and carries the full message")
    func getDraftRequest() async throws {
        let recorder = Recorder([.http(200, """
            {"id":"r1","message":{"id":"m1","threadId":"t1","labelIds":["DRAFT"],"snippet":"hello",
              "historyId":"9","internalDate":"1700000000000","sizeEstimate":300,
              "payload":{"mimeType":"text/plain","headers":[{"name":"To","value":"a@b.c"}],"body":{"size":5,"data":"aGVsbG8"}}}}
            """)])
        let draft = try await Self.client(recorder).getDraft(accessToken: "t", draftId: "r1", format: .metadata)
        #expect(recorder.last.httpMethod == "GET")
        #expect(recorder.last.url!.path() == "/gmail/v1/users/me/drafts/r1")
        #expect(Self.items(recorder.last, "format") == ["metadata"])
        #expect(draft.message?.snippet == "hello")
        #expect(draft.message?.payload?.headers?.first?.value == "a@b.c")
        #expect(draft.message?.payload?.body?.data == "aGVsbG8")
    }

    @Test("getDraft is idempotent: a 500 is retried")
    func getDraftRetried() async throws {
        let recorder = Recorder([.http(500, "{}"), .http(200, #"{"id":"r1","message":{"id":"m1"}}"#)])
        let draft = try await Self.client(recorder).getDraft(accessToken: "t", draftId: "r1")
        #expect(draft.message?.id == "m1" && draft.message?.payload == nil)
        #expect(recorder.attempts == 2)
        #expect(Self.items(recorder.last, "format") == ["full"])
    }

    // MARK: - Query parameters

    @Test("metadataHeaders are repeated items at .metadata and omitted at other formats")
    func metadataHeaders() async throws {
        let recorder = Recorder([.http(200, Self.messageOK)])
        let client = Self.client(recorder)
        _ = try await client.getMessage(accessToken: "t", messageId: "m1", format: .metadata, metadataHeaders: ["From", "Subject"])
        #expect(Self.items(recorder.last, "metadataHeaders") == ["From", "Subject"])
        _ = try await client.getMessage(tokenSource: .fixed("t"), messageId: "m1", format: .metadata, metadataHeaders: ["Date"])
        #expect(Self.items(recorder.last, "metadataHeaders") == ["Date"])
        _ = try await client.getMessage(accessToken: "t", messageId: "m1", format: .full, metadataHeaders: ["From"])
        #expect(Self.items(recorder.last, "metadataHeaders").isEmpty)
    }

    @Test("listHistory sends repeated historyTypes and maxResults on both variants; MessageRef carries labelIds")
    func historyParameters() async throws {
        let body = """
            {"history":[{"id":"5","messagesAdded":[{"message":{"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"]}}]}],
             "historyId":"6"}
            """
        let recorder = Recorder([.http(200, body)])
        let client = Self.client(recorder)
        let page = try await client.listHistory(
            accessToken: "t", startHistoryId: "4", historyTypes: ["messageAdded", "labelRemoved"], maxResults: 50
        )
        #expect(Self.items(recorder.last, "historyTypes") == ["messageAdded", "labelRemoved"])
        #expect(Self.items(recorder.last, "maxResults") == ["50"])
        #expect(page.history?.first?.messagesAdded?.first?.message.labelIds == ["INBOX", "UNREAD"])

        _ = try await client.listHistory(tokenSource: .fixed("t"), startHistoryId: "4", historyTypes: ["labelAdded"])
        #expect(Self.items(recorder.last, "historyTypes") == ["labelAdded"])
        #expect(Self.items(recorder.last, "maxResults").isEmpty)
    }

    @Test("listMessages sends repeated labelIds items")
    func listMessagesLabelIds() async throws {
        let recorder = Recorder([.http(200, #"{"resultSizeEstimate":0}"#)])
        let client = Self.client(recorder)
        _ = try await client.listMessages(accessToken: "t", query: "", labelIds: ["INBOX", "Label_7"])
        #expect(Self.items(recorder.last, "labelIds") == ["INBOX", "Label_7"])
        _ = try await client.listMessages(accessToken: "t", query: "")
        #expect(Self.items(recorder.last, "labelIds").isEmpty)
    }

    // MARK: - Token-source variants

    /// Hands out "old" until asked to refresh, then "new"; counts refreshes.
    private final class Tokens: @unchecked Sendable {
        private let lock = NSLock()
        private var refreshes = 0
        var refreshCount: Int { lock.withLock { refreshes } }
        var source: GmailTokenSource {
            GmailTokenSource { [self] rejected in
                lock.withLock {
                    if rejected != nil { refreshes += 1 }
                    return refreshes > 0 ? "new" : "old"
                }
            }
        }
    }

    @Test("send via tokenSource: 401 → one refresh → 200, exactly two attempts")
    func sendTokenSourceRefreshes() async throws {
        let tokens = Tokens()
        let recorder = Recorder([.http(401, "{}"), .http(200, Self.sendOK)])
        let sent = try await Self.client(recorder).sendMessage(tokenSource: tokens.source, rawMessage: "raw")
        #expect(sent.id == "m1")
        #expect(recorder.attempts == 2)
        #expect(tokens.refreshCount == 1)
        #expect(recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
    }

    @Test("send via tokenSource: a 500 is one attempt and no refresh")
    func sendTokenSourceServerError() async throws {
        let tokens = Tokens()
        let recorder = Recorder([.http(500, "{}"), .http(200, Self.sendOK)])
        await #expect(throws: GmailAPIError.httpError(statusCode: 500)) {
            _ = try await Self.client(recorder).sendMessage(tokenSource: tokens.source, rawMessage: "raw")
        }
        #expect(recorder.attempts == 1)
        #expect(tokens.refreshCount == 0)
    }

    @Test("send via tokenSource: a 401 that survives the refresh is a credential error, not a third attempt")
    func sendTokenSourceRefreshedRejected() async throws {
        let tokens = Tokens()
        let recorder = Recorder([.http(401, "{}")])
        do {
            _ = try await Self.client(recorder).sendMessage(tokenSource: tokens.source, rawMessage: "raw")
            Issue.record("expected a throw")
        } catch let error as GmailAPIError {
            guard case .authenticationFailed = error else { Issue.record("got \(error)"); return }
            #expect(!GmailAPIError.isAmbiguousDelivery(error))
        }
        #expect(recorder.attempts == 2)
        #expect(tokens.refreshCount == 1)
    }

    @Test("createDraft, getDraft, getThread and getAttachment via tokenSource refresh once on a 401")
    func otherTokenSourceVariants() async throws {
        let ok = #"{"id":"r1","message":{"id":"m1"},"messages":[],"size":1,"data":"QQ"}"#
        for call in 0..<4 {
            let tokens = Tokens()
            let recorder = Recorder([.http(401, "{}"), .http(200, ok)])
            let client = Self.client(recorder)
            switch call {
            case 0: _ = try await client.createDraft(tokenSource: tokens.source, rawMessage: "raw")
            case 1: _ = try await client.getDraft(tokenSource: tokens.source, draftId: "r1")
            case 2: _ = try await client.getThread(tokenSource: tokens.source, threadId: "r1")
            default:
                let data = try await client.getAttachment(tokenSource: tokens.source, messageId: "m1", attachmentId: "a1")
                #expect(data == Data("A".utf8))
            }
            #expect(recorder.attempts == 2, "call \(call)")
            #expect(tokens.refreshCount == 1, "call \(call)")
            #expect(recorder.last.value(forHTTPHeaderField: "Authorization") == "Bearer new")
        }
    }

    // MARK: - labels.get

    private static let labelOK = """
        {"id":"Label_12","name":"Receipts","messageListVisibility":"show","labelListVisibility":"labelShow",
          "type":"user","messagesTotal":1234,"messagesUnread":56,"threadsTotal":789,"threadsUnread":42,
          "color":{"textColor":"#ffffff","backgroundColor":"#16a765"}}
        """

    @Test("getLabel GETs labels/{id} with the id encoded as one segment")
    func getLabelRequest() async throws {
        let recorder = Recorder([.http(200, Self.labelOK)])
        _ = try await Self.client(recorder).getLabel(accessToken: "t", labelId: "../x?y")
        #expect(recorder.last.httpMethod == "GET")
        #expect(recorder.last.url!.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels/..%2Fx%3Fy")
    }

    @Test("getLabel decodes the message and thread counts")
    func getLabelDecodes() async throws {
        let recorder = Recorder([.http(200, Self.labelOK)])
        let label = try await Self.client(recorder).getLabel(accessToken: "t", labelId: "Label_12")
        #expect(label.id == "Label_12" && label.name == "Receipts")
        #expect(label.messagesTotal == 1234)
        #expect(label.messagesUnread == 56)
        #expect(label.threadsTotal == 789)
        #expect(label.threadsUnread == 42)
    }

    @Test("getLabel is idempotent: a 503 is retried")
    func getLabelRetried() async throws {
        let recorder = Recorder([.http(503, "{}"), .http(200, Self.labelOK)])
        let label = try await Self.client(recorder).getLabel(accessToken: "t", labelId: "Label_12")
        #expect(label.threadsUnread == 42)
        #expect(recorder.attempts == 2)
    }

    @Test("getLabel is charged labels.get's units, not labels.list's or drafts.get's")
    func getLabelCharge() async throws {
        let d = GmailUnitCost.documented
        let cost = GmailUnitCost(
            getProfile: d.getProfile, labelsList: 1, historyList: d.historyList,
            messagesList: d.messagesList, messagesGet: d.messagesGet, messagesModify: d.messagesModify,
            messagesTrash: d.messagesTrash, messagesUntrash: d.messagesUntrash,
            messagesDelete: d.messagesDelete, messagesBatchModify: d.messagesBatchModify,
            messagesSend: d.messagesSend, attachmentsGet: d.attachmentsGet, threadsList: d.threadsList,
            threadsGet: d.threadsGet, draftsList: d.draftsList, draftsCreate: d.draftsCreate,
            draftsUpdate: d.draftsUpdate, draftsDelete: d.draftsDelete,
            draftsGet: 5, draftsSend: d.draftsSend, labelsCreate: d.labelsCreate, labelsGet: 7
        )
        let clock = VirtualClock()
        let start = clock.now
        let bucket = GmailQuotaBucket(
            now: { clock.now }, sleeper: { clock.advance($0) },
            profile: GmailQuotaProfile(unitsPerSecond: 10, perUserUnitsPerSecond: 10, unitCost: cost)
        )
        let recorder = Recorder([.http(200, Self.labelOK)])
        let client = GmailAPIClient(quotaBucket: bucket, transport: { try recorder.respond(to: $0) })
        _ = try await client.getLabel(accessToken: "t", labelId: "Label_12", quotaKey: "k")
        // A fresh bucket's interactive clock moves by units / rate: 7 / 10 u/s.
        let pushed = try #require(await bucket.buckets["k"]?.nextFreeInteractive)
        #expect(abs(pushed.timeIntervalSince(start) - 0.7) < 0.001, "charged \(pushed.timeIntervalSince(start) * 10) units")
        #expect(GmailUnitCost.documented.labelsGet == 1)
    }

    @Test("getLabel via tokenSource refreshes once on a 401")
    func getLabelTokenSource() async throws {
        let tokens = Tokens()
        let recorder = Recorder([.http(401, "{}"), .http(200, Self.labelOK)])
        let label = try await Self.client(recorder).getLabel(tokenSource: tokens.source, labelId: "Label_12")
        #expect(label.messagesUnread == 56)
        #expect(recorder.attempts == 2)
        #expect(tokens.refreshCount == 1)
        #expect(recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
    }

    @Test("send and createDraft via tokenSource: a timeout is one attempt and no refresh", arguments: [true, false])
    func tokenSourceTimeoutNotRetried(isSend: Bool) async throws {
        let tokens = Tokens()
        let recorder = Recorder([.fail(.timedOut), .http(200, #"{"id":"m1","threadId":"t1"}"#)])
        let client = Self.client(recorder)
        await #expect(throws: URLError.self) {
            if isSend {
                _ = try await client.sendMessage(tokenSource: tokens.source, rawMessage: "raw")
            } else {
                _ = try await client.createDraft(tokenSource: tokens.source, rawMessage: "raw")
            }
        }
        #expect(recorder.attempts == 1)
        #expect(tokens.refreshCount == 0)
    }

    @Test("createDraft via tokenSource: a 500 is one attempt")
    func createDraftTokenSourceServerError() async throws {
        let recorder = Recorder([.http(500, "{}"), .http(200, #"{"id":"r1"}"#)])
        await #expect(throws: GmailAPIError.httpError(statusCode: 500)) {
            _ = try await Self.client(recorder).createDraft(tokenSource: Tokens().source, rawMessage: "raw")
        }
        #expect(recorder.attempts == 1)
    }
}
