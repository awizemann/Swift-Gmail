import Foundation
import os
import Testing
@testable import SwiftGmail

/// `awaitAbandoningOnCancel` — stop WAITING on cancel, never stop the work.
@Suite("awaitAbandoningOnCancel")
struct AbandonOnCancelWaitTests {

    /// A latch the underlying task polls, so it can be held open and released
    /// from the test without caring about its own cancellation.
    private final class Latch: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        func open() { state.withLock { $0 = true } }
        var isOpen: Bool { state.withLock { $0 } }
        func wait() async {
            while !isOpen { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    private struct Boom: Error, Equatable { let code: Int }

    @Test("An already-cancelled caller gets CancellationError at once; the underlying task is not cancelled and runs on")
    func alreadyCancelledCaller() async throws {
        let latch = Latch()
        let underlying = Task<Int, Error> {
            await latch.wait()
            return 7
        }
        let caller = Task<Int, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await awaitAbandoningOnCancel(underlying)
        }
        let outcome = await caller.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(!underlying.isCancelled, "the caller's cancel leaked into the awaited task")

        latch.open()
        #expect(try await underlying.value == 7, "the underlying task should run to completion")
    }

    @Test("The underlying task's own error passes through unchanged")
    func errorPassesThrough() async throws {
        let underlying = Task<Int, Error> { throw Boom(code: 42) }
        let outcome = await Task<Int, Error> { try await awaitAbandoningOnCancel(underlying) }.result
        #expect(throws: Boom(code: 42)) { try outcome.get() }
    }

    @Test("A success arriving concurrently with the cancel resumes exactly once, every time")
    func raceResumesExactlyOnce() async throws {
        // A double resume of a CheckedContinuation traps, and a lost one hangs
        // — either would fail this loop. Each round must end with exactly one
        // of the two legal outcomes.
        var successes = 0
        var cancellations = 0
        for round in 0..<400 {
            let underlying = Task<Int, Error> { round }
            let caller = Task<Int, Error> { try await awaitAbandoningOnCancel(underlying) }
            caller.cancel()
            switch await caller.result {
            case .success(let value):
                #expect(value == round)
                successes += 1
            case .failure(let error):
                #expect(error is CancellationError, "unexpected error \(error)")
                cancellations += 1
            }
        }
        #expect(successes + cancellations == 400)
    }
}
