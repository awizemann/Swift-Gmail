//
//  AbandonOnCancelWait.swift
//  SwiftGmail
//
//  "Stop WAITING when my caller is cancelled, but let the work run on."
//
//  `Task.value` ignores the awaiting task's cancellation: a caller parked on
//  an unstructured task's value stays parked until that task finishes, however
//  long that is. The sync engine parks on unstructured tasks in three shared
//  places — the coalescing `inFlight` slots, the per-account action-drain lane
//  and the per-account draft-op lane — and each is unstructured ON PURPOSE
//  (other callers join or chain behind it, so it must not die with whichever
//  caller happened to start it).
//
//  That combination is what froze iOS background refresh (2026-10-04): the
//  `BGAppRefreshTask` expiry cancelled its work, but the work was parked on a
//  slot it could not leave. This helper is the one place that pattern is
//  solved: the caller gets `CancellationError` the moment it is cancelled, and
//  the awaited task keeps running for whoever else depends on it.
//

import Foundation
import os

/// Await `task`'s value, but throw `CancellationError` as soon as the CALLING
/// task is cancelled. `task` itself is NOT cancelled — it runs to completion
/// in the background, and its result is then discarded by this waiter.
///
/// Use only where abandoning the wait is safe: the awaited work must own its
/// own bookkeeping (slot release, cursor stamps) rather than relying on this
/// caller to finish it.
public func awaitAbandoningOnCancel<T: Sendable, E: Error>(_ task: Task<T, E>) async throws -> T {
    let gate = AbandonableWaitGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            // Already resolved (the caller was cancelled before we got here):
            // nothing to relay.
            guard !gate.install(continuation) else { return }
            // The relay is the only thing that awaits `task`; it outlives an
            // abandoned wait by exactly as long as `task` runs, then resolves
            // a gate nobody is listening to any more.
            Task {
                do {
                    gate.resolve(.success(try await task.value))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
        }
    } onCancel: {
        gate.resolve(.failure(CancellationError()))
    }
}

/// First-result-wins handoff between the relay, the cancellation handler and
/// the continuation, which may arrive in any order (the cancellation handler
/// can fire before the continuation is even installed).
///
/// `@unchecked Sendable`: all state lives behind the unfair lock, and the
/// continuation is resumed outside it, exactly once.
private final class AbandonableWaitGate<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var early: Result<T, Error>?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Returns true when the gate was ALREADY resolved and `continuation` has
    /// been resumed on the spot.
    @discardableResult
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let ready = state.withLock { s -> Result<T, Error>? in
            guard let early = s.early else {
                s.continuation = continuation
                return nil
            }
            s.finished = true
            return early
        }
        guard let ready else { return false }
        continuation.resume(with: ready)
        return true
    }

    func resolve(_ result: Result<T, Error>) {
        let target = state.withLock { s -> CheckedContinuation<T, Error>? in
            guard !s.finished else { return nil }
            if let continuation = s.continuation {
                s.finished = true
                s.continuation = nil
                return continuation
            }
            // Not installed yet: park the FIRST result for `install`.
            if s.early == nil { s.early = result }
            return nil
        }
        target?.resume(with: result)
    }
}
