import Foundation

/// The one request/response + demux mechanism, in `Data`.
///
/// Two subsystems had independently grown this shape and disagreed about it — one
/// with a timeout, one able to await a silent device for ever — so it is stated
/// once here rather than reinvented per vendor. Its three callers are a serial
/// toy's session, a high-rate sensor's whose replies and data arrive on separate
/// characteristics, and a notify-only reader that has neither shape on its own.
/// A further vendor adds a caller, not a copy.
///
/// It owns no connection and no vendor vocabulary: byte sources go in through
/// `consume`, and frames come out either to a **standing subscription** (a stream)
/// or to the **outstanding request** (a one-shot that can time out). A standing
/// subscription consumes its frame before any request sees it — so a sensor frame
/// cannot answer a query — and that rule is stated here once instead of twice by
/// accident.
///
/// Sources are plural because the separation between replies and data may come
/// from the wire (a control point distinct from its data characteristic) or not at
/// all (one serial rx carrying both); neither is assumed.
public actor DeviceSession {
    /// A handle to a standing subscription, for cancelling it before its consumer
    /// drops the stream.
    public struct Subscription: Hashable, Sendable {
        fileprivate let token = UUID()
    }

    /// One standing subscription's producer side. A class, not a struct, so that
    /// its lifetime *is* the stream's: dropping a continuation does not finish
    /// the stream — the consumer suspends for ever — and an actor's `deinit` is
    /// nonisolated and may not touch a non-Sendable stored property, so the entry
    /// finishes for itself. Every path that ends a subscription, including the
    /// session being dropped without `stop`, is then the same path: the entry
    /// goes away.
    private final class Standing {
        let subscription: Subscription
        /// Yields the frame if it matches, and reports whether it did.
        let deliver: (Data) -> Bool
        private let finish: () -> Void

        init(subscription: Subscription, deliver: @escaping (Data) -> Bool, finish: @escaping () -> Void) {
            self.subscription = subscription
            self.deliver = deliver
            self.finish = finish
        }

        deinit { finish() }
    }

    private struct Waiter {
        /// Resumes the request if the frame matches, and reports whether it did.
        let deliver: (Data) -> Bool
        let fail: (Error) -> Void
    }

    private var sourceTasks: [Task<Void, Never>] = []
    private var attachedSources = 0
    private var liveSources = 0
    private var stopped = false
    private var standing: [Standing] = []
    private var waiter: Waiter?

    public init() {}

    /// A session dropped without `stop` ends the same way `stop` ends it: the
    /// pumps are cancelled here — `Task` handles are Sendable, so a nonisolated
    /// deinit may reach them — and `standing` finishes its own streams as it dies.
    deinit {
        for task in sourceTasks { task.cancel() }
    }

    /// Whether every attached source has finished, or `stop` was called. A session
    /// with no source yet is not done — it is waiting for one.
    private var isDone: Bool { stopped || (attachedSources > 0 && liveSources == 0) }

    // MARK: Sources

    /// Attaches a byte source. One task per source; the actor serialises delivery,
    /// so frames from several characteristics interleave safely.
    ///
    /// `framing` splits one notification into messages. The default is identity —
    /// one notification, one message — which is what every binary profile here
    /// wants; a serial protocol passes its own terminator-splitting framer.
    public func consume(_ source: AsyncStream<Data>,
                        framing: @escaping @Sendable (Data) -> [Data] = { [$0] }) {
        attachedSources += 1
        liveSources += 1
        sourceTasks.append(Task { [weak self] in
            for await chunk in source where !chunk.isEmpty {
                for frame in framing(chunk) { await self?.deliver(frame) }
            }
            await self?.sourceFinished()
        })
    }

    /// Cancels the source tasks, finishes every subscription, and cancels the
    /// outstanding request. The caller disconnects its own connection.
    public func stop() {
        stopped = true
        for task in sourceTasks { task.cancel() }
        sourceTasks = []
        liveSources = 0
        standing = []
        failRequest(CancellationError())
    }

    // MARK: Requests

    /// Sends nothing — the caller writes — and awaits the first frame `select`
    /// accepts, for `timeout` at most.
    ///
    /// Matching and parsing are one act: `select` returns the parsed value or nil,
    /// so a frame is never parsed twice. At most one request is outstanding; a
    /// second supersedes the first, which throws `CancellationError`. Throws
    /// `SessionError.timedOut` if nothing matches in time, and
    /// `TransportError.notConnected` if the sources run out first.
    public func request<T: Sendable>(timeout: Duration,
                                     matching select: @escaping @Sendable (Data) -> T?) async throws -> T {
        guard !isDone else { throw TransportError.notConnected }
        // `try`, not `try?`: a cancelled sleep must end the task, not fall through
        // to fail whichever waiter is registered by then — which, once this request
        // has been answered and the `defer` has cancelled, is the *next* one's.
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.failRequest(SessionError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            failRequest(CancellationError())   // supersede any prior request
            waiter = Waiter(deliver: { frame in
                                guard let value = select(frame) else { return false }
                                continuation.resume(returning: value)
                                return true
                            },
                            fail: { continuation.resume(throwing: $0) })
        }
    }

    // MARK: Subscriptions

    /// A standing stream of every frame `select` accepts, for as long as the
    /// session lives. `onTermination` runs when the consumer drops the stream or
    /// `cancel` ends it — the hook a caller needs to switch the device's own stream
    /// off again. It is async and runs on the session's own task, so a caller need
    /// not spawn one to get back into its actor.
    public func subscribe<T: Sendable>(_ select: @escaping @Sendable (Data) -> T?,
                                       onTermination: (@Sendable () async -> Void)? = nil)
        -> (Subscription, AsyncStream<T>) {
        let subscription = Subscription()
        let (stream, continuation) = AsyncStream.makeStream(of: T.self)
        guard !isDone else {
            continuation.finish()
            return (subscription, stream)
        }
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.cancel(subscription)
                await onTermination?()
            }
        }
        standing.append(Standing(subscription: subscription,
                                 deliver: { frame in
                                     guard let value = select(frame) else { return false }
                                     continuation.yield(value)
                                     return true
                                 },
                                 finish: { continuation.finish() }))
        return (subscription, stream)
    }

    /// Ends one subscription's stream. Idempotent.
    public func cancel(_ subscription: Subscription) {
        standing.removeAll { $0.subscription == subscription }
    }

    // MARK: Dispatch

    /// Subscriptions first, in the order they were made, then the request. Only the
    /// first match consumes the frame; overlapping predicates are the caller's
    /// business to avoid.
    private func deliver(_ frame: Data) {
        for entry in standing where entry.deliver(frame) { return }
        guard let waiter, waiter.deliver(frame) else { return }
        self.waiter = nil
    }

    /// The last source finishing means the link is gone: nothing more will ever
    /// arrive, so a caller awaiting a reply is told now rather than at its timeout.
    private func sourceFinished() {
        guard liveSources > 0 else { return }
        liveSources -= 1
        guard liveSources == 0 else { return }
        standing = []
        failRequest(TransportError.notConnected)
    }

    private func failRequest(_ error: Error) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.fail(error)
    }
}

/// How a device session fails, whichever vendor's session it is. `Actuator` is
/// declared here, so the vocabulary its methods throw belongs here too: both
/// vendor kits had arrived at the same two cases independently.
public enum SessionError: Error, Equatable {
    /// No frame matched the request within its timeout.
    case timedOut
    /// A command needing the model was issued before `identify`, or identification
    /// itself did not yield a model.
    case notIdentified
    /// The device has no feature of the requested kind — rotation on a vibrator,
    /// or a motor ordinal it does not have.
    case featureUnavailable(String)
}

extension SessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timedOut: return "Device did not reply in time"
        case .notIdentified: return "Device has not been identified"
        case .featureUnavailable(let feature): return "Device has no \(feature)"
        }
    }
}
