import Foundation
import Testing
@testable import SwiftGmail

/// End-to-end error handling through the injected `Transport`: which responses
/// each endpoint retries, what it throws, and the `GmailErrorDetail` it parses.
/// The bucket's sleeper is a no-op, so `withRetry`'s backoff (which waits on
/// it) costs no wall-clock time.
@Suite("GmailAPIClient — error classification and retry per endpoint")
struct GmailAPIClientErrorHandlingTests {

    /// Replays a fixed script of responses (the last one repeats) and counts
    /// requests. Calls are sequential, but guard with a lock anyway.
    private final class ScriptedTransport: @unchecked Sendable {
        enum Step { case http(Int, String, [String: String] = [:]), fail(URLError.Code) }
        private let lock = NSLock()
        private let steps: [Step]
        private var index = 0
        init(_ steps: [Step]) { self.steps = steps }

        var attempts: Int { lock.withLock { index } }

        func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            let step: Step = lock.withLock {
                defer { index += 1 }
                return steps[min(index, steps.count - 1)]
            }
            switch step {
            case .fail(let code):
                throw URLError(code)
            case .http(let status, let body, let headers):
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
                )!
                return (Data(body.utf8), response)
            }
        }
    }

    private static func client(_ transport: ScriptedTransport) -> GmailAPIClient {
        GmailAPIClient(quotaBucket: GmailQuotaBucket(sleeper: { _ in })) { try transport.respond(to: $0) }
    }

    /// Decodes as every response type the endpoints below expect.
    private static let okBody = """
        {"id":"m1","threadId":"t1","snippet":"","internalDate":"0","historyId":"1",
         "messages":[],"labels":[],"emailAddress":"a@b.c","size":0,"data":""}
        """

    private static func errorBody(_ code: Int, reason: String, message: String, status: String) -> String {
        """
        {"error":{"code":\(code),"message":"\(message)",
          "errors":[{"message":"\(message)","domain":"usageLimits","reason":"\(reason)"}],
          "status":"\(status)"}}
        """
    }

    private static let forbiddenBody = """
        {"error":{"code":403,"message":"Request had insufficient authentication scopes.",
          "errors":[{"message":"Insufficient Permission","domain":"global","reason":"insufficientPermissions"}],
          "status":"PERMISSION_DENIED"}}
        """

    // MARK: - messages.send / drafts.create never double-create

    @Test("send: a 500 is not retried — one attempt, httpError(500)")
    func sendServerErrorNotRetried() async throws {
        let transport = ScriptedTransport([.http(500, "{}"), .http(200, Self.okBody)])
        let client = Self.client(transport)
        do {
            _ = try await client.sendMessage(accessToken: "t", rawMessage: "raw")
            Issue.record("expected a throw")
        } catch let error as GmailAPIError {
            #expect(error == .httpError(statusCode: 500))
        }
        #expect(transport.attempts == 1)
    }

    @Test("send: a 429 is retried (rejected before acceptance) and then succeeds")
    func sendRateLimitRetried() async throws {
        let transport = ScriptedTransport([.http(429, "{}"), .http(200, Self.okBody)])
        let response = try await Self.client(transport).sendMessage(accessToken: "t", rawMessage: "raw")
        #expect(response.id == "m1")
        #expect(transport.attempts == 2)
    }

    @Test("send: a client timeout is not retried — one attempt")
    func sendTimeoutNotRetried() async throws {
        let transport = ScriptedTransport([.fail(.timedOut), .http(200, Self.okBody)])
        await #expect(throws: URLError.self) {
            _ = try await Self.client(transport).sendMessage(accessToken: "t", rawMessage: "raw")
        }
        #expect(transport.attempts == 1)
    }

    @Test("drafts.create: a 500 is not retried — a retry could leave a duplicate draft")
    func createDraftServerErrorNotRetried() async throws {
        let transport = ScriptedTransport([.http(500, "{}"), .http(200, Self.okBody)])
        await #expect(throws: GmailAPIError.httpError(statusCode: 500)) {
            _ = try await Self.client(transport).createDraft(accessToken: "t", rawMessage: "raw")
        }
        #expect(transport.attempts == 1)
    }

    // MARK: - Error detail

    @Test("A Gmail-shaped error body and Retry-After header populate the detail")
    func detailParsedFromBody() async throws {
        let transport = ScriptedTransport([.http(404, """
            {"error":{"code":404,"message":"Requested entity was not found.",
              "errors":[{"message":"Requested entity was not found.","domain":"global","reason":"notFound"}],
              "status":"NOT_FOUND"}}
            """, ["Retry-After": "30"])])
        let expected = GmailAPIError.httpError(statusCode: 404, detail: GmailErrorDetail(
            reason: "notFound", message: "Requested entity was not found.", retryAfter: 30
        ))
        await #expect(throws: expected) {
            _ = try await Self.client(transport).getMessage(accessToken: "t", messageId: "m1")
        }
        #expect(transport.attempts == 1)
        #expect(expected.errorDescription?.contains("notFound") == true)
    }

    @Test("A body with only `error.status` uses it as the reason")
    func detailFallsBackToStatus() async throws {
        let transport = ScriptedTransport([.http(400, #"{"error":{"code":400,"message":"Bad","status":"INVALID_ARGUMENT"}}"#)])
        await #expect(throws: GmailAPIError.httpError(
            statusCode: 400, detail: GmailErrorDetail(reason: "INVALID_ARGUMENT", message: "Bad")
        )) {
            _ = try await Self.client(transport).getProfile(accessToken: "t")
        }
    }

    // MARK: - Daily quota versus per-user rate

    @Test("A daily-limit 403 throws quotaExceeded and is not retried", arguments: ["dailyLimitExceeded", "DailyLimitExceeded"])
    func dailyLimitNotRetried(reason: String) async throws {
        let body = Self.errorBody(403, reason: reason, message: "Daily Limit Exceeded", status: "PERMISSION_DENIED")
        let transport = ScriptedTransport([.http(403, body), .http(200, Self.okBody)])
        await #expect(throws: GmailAPIError.quotaExceeded) {
            _ = try await Self.client(transport).getMessage(accessToken: "t", messageId: "m1")
        }
        #expect(transport.attempts == 1)
    }

    @Test("A daily-limit 429 throws quotaExceeded too")
    func dailyLimit429() async throws {
        let body = Self.errorBody(429, reason: "dailyLimitExceeded", message: "Daily Limit Exceeded", status: "RESOURCE_EXHAUSTED")
        let transport = ScriptedTransport([.http(429, body), .http(200, Self.okBody)])
        await #expect(throws: GmailAPIError.quotaExceeded) {
            _ = try await Self.client(transport).listLabels(accessToken: "t")
        }
        #expect(transport.attempts == 1)
    }

    @Test("A quotaExceeded 403 (per-minute / concurrency quota) is retried")
    func quotaExceededReasonRetried() async throws {
        let body = Self.errorBody(403, reason: "quotaExceeded", message: "Quota exceeded", status: "RESOURCE_EXHAUSTED")
        let transport = ScriptedTransport([.http(403, body), .http(200, Self.okBody)])
        let message = try await Self.client(transport).getMessage(accessToken: "t", messageId: "m1")
        #expect(message.id == "m1")
        #expect(transport.attempts == 2)
    }

    @Test("send: a rate-limit 403 is retried and then succeeds")
    func sendRate403Retried() async throws {
        let body = Self.errorBody(403, reason: "userRateLimitExceeded", message: "Rate Limit Exceeded", status: "PERMISSION_DENIED")
        let transport = ScriptedTransport([.http(403, body), .http(200, Self.okBody)])
        let response = try await Self.client(transport).sendMessage(accessToken: "t", rawMessage: "raw")
        #expect(response.id == "m1")
        #expect(transport.attempts == 2)
    }

    @Test("send: a dailyLimitExceeded 403 throws quotaExceeded after one attempt")
    func sendDailyLimitNotRetried() async throws {
        let body = Self.errorBody(403, reason: "dailyLimitExceeded", message: "Daily Limit Exceeded", status: "PERMISSION_DENIED")
        let transport = ScriptedTransport([.http(403, body), .http(200, Self.okBody)])
        await #expect(throws: GmailAPIError.quotaExceeded) {
            _ = try await Self.client(transport).sendMessage(accessToken: "t", rawMessage: "raw")
        }
        #expect(transport.attempts == 1)
    }

    @Test("An empty error body leaves detail nil")
    func emptyBodyHasNilDetail() async throws {
        let transport = ScriptedTransport([.http(500, "<html>oops</html>")])
        await #expect(throws: GmailAPIError.httpError(statusCode: 500, detail: nil)) {
            _ = try await Self.client(transport).sendMessage(accessToken: "t", rawMessage: "raw")
        }
    }

    // MARK: - messages.delete

    @Test("delete: a 503 then a 404 succeeds — the first attempt deleted it")
    func deleteRetry404IsSuccess() async throws {
        let transport = ScriptedTransport([.http(503, "{}"), .http(404, "{}")])
        try await Self.client(transport).deleteMessage(accessToken: "t", messageId: "m1")
        #expect(transport.attempts == 2)
    }

    @Test("delete: a first-attempt 404 still throws")
    func deleteFirst404Throws() async throws {
        let transport = ScriptedTransport([.http(404, "{}")])
        await #expect(throws: GmailAPIError.httpError(statusCode: 404)) {
            try await Self.client(transport).deleteMessage(accessToken: "t", messageId: "m1")
        }
        #expect(transport.attempts == 1)
    }

    @Test("A rateLimitExceeded 403 is retried and then succeeds")
    func rateLimit403Retried() async throws {
        let body = Self.errorBody(403, reason: "rateLimitExceeded", message: "Rate Limit Exceeded", status: "PERMISSION_DENIED")
        let transport = ScriptedTransport([.http(403, body), .http(200, Self.okBody)])
        let message = try await Self.client(transport).getMessage(accessToken: "t", messageId: "m1")
        #expect(message.id == "m1")
        #expect(transport.attempts == 2)
    }

    // MARK: - Every idempotent endpoint shares the classifier and the retry

    enum Endpoint: String, CaseIterable, Sendable {
        case listMessages, listDrafts, getProfile, listLabels, listHistory, listHistoryTokenSource,
             listThreads, getThread, getMessage, getAttachment, modifyMessage, batchModifyMessages,
             trashMessage, untrashMessage, deleteMessage, updateDraft, deleteDraft

        func call(_ client: GmailAPIClient) async throws {
            switch self {
            case .listMessages: _ = try await client.listMessages(accessToken: "t", query: "q")
            case .listDrafts: _ = try await client.listDrafts(accessToken: "t")
            case .getProfile: _ = try await client.getProfile(accessToken: "t")
            case .listLabels: _ = try await client.listLabels(accessToken: "t")
            case .listHistory: _ = try await client.listHistory(accessToken: "t", startHistoryId: "1")
            case .listHistoryTokenSource:
                _ = try await client.listHistory(tokenSource: .fixed("t"), startHistoryId: "1")
            case .listThreads: _ = try await client.listThreads(accessToken: "t", query: "q")
            case .getThread: _ = try await client.getThread(accessToken: "t", threadId: "t1")
            case .getMessage: _ = try await client.getMessage(accessToken: "t", messageId: "m1")
            case .getAttachment: _ = try await client.getAttachment(accessToken: "t", messageId: "m1", attachmentId: "a1")
            case .modifyMessage: try await client.modifyMessage(accessToken: "t", messageId: "m1", addLabelIds: ["STARRED"])
            case .batchModifyMessages: try await client.batchModifyMessages(accessToken: "t", messageIds: ["m1"], addLabelIds: ["STARRED"])
            case .trashMessage: try await client.trashMessage(accessToken: "t", messageId: "m1")
            case .untrashMessage: try await client.untrashMessage(accessToken: "t", messageId: "m1")
            case .deleteMessage: try await client.deleteMessage(accessToken: "t", messageId: "m1")
            case .updateDraft: try await client.updateDraft(accessToken: "t", draftId: "d1", rawMessage: "raw")
            case .deleteDraft: try await client.deleteDraft(accessToken: "t", draftId: "d1")
            }
        }
    }

    @Test("A 503 then a 200 succeeds after one retry", arguments: Endpoint.allCases)
    func serverErrorRetried(endpoint: Endpoint) async throws {
        let transport = ScriptedTransport([.http(503, "{}"), .http(200, Self.okBody)])
        try await endpoint.call(Self.client(transport))
        #expect(transport.attempts == 2)
    }

    @Test("A forbidden 403 is not retried and carries its detail", arguments: Endpoint.allCases)
    func forbiddenNotRetried(endpoint: Endpoint) async throws {
        let transport = ScriptedTransport([.http(403, Self.forbiddenBody), .http(200, Self.okBody)])
        await #expect(throws: GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(
            reason: "insufficientPermissions", message: "Request had insufficient authentication scopes."
        ))) {
            try await endpoint.call(Self.client(transport))
        }
        #expect(transport.attempts == 1)
    }

    @Test("history.list keeps its 404 → historyIdExpired mapping")
    func historyExpiredPreserved() async throws {
        let transport = ScriptedTransport([.http(404, "{}")])
        await #expect(throws: GmailAPIError.historyIdExpired) {
            _ = try await Self.client(transport).listHistory(accessToken: "t", startHistoryId: "1")
        }
        #expect(transport.attempts == 1)
    }
}
