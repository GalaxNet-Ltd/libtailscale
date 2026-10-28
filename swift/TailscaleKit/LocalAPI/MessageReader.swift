// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

enum MessageQueueError: Error, Equatable {
    case queueCongested
    case unexpectedEndOfStream
}

let kMaxQueueSize = 24

struct WatchStartupTrace: Sendable {
    private let logger: (any LogSink)?
    private let identifier = UUID().uuidString
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    init(logger: (any LogSink)?) { self.logger = logger }
    func record(_ phase: String) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        logger?.log("IPN watch startup id=\(identifier) transport=in-process phase=\(phase) elapsed_ms=\(elapsed)")
    }
}

private final class IPNMessageBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = 0
    init(limit: Int) { self.limit = limit }
    func reserve(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count <= limit - bytes else { return false }
        bytes += count
        return true
    }
    func release(_ count: Int) {
        lock.lock()
        bytes -= count
        lock.unlock()
    }
}

/// Accounts for queued and currently consumed bytes, including a large netmap.
final class IPNMessage: Sendable {
    let data: Data
    private let budget: IPNMessageBudget
    fileprivate init(data: Data, budget: IPNMessageBudget) { self.data = data; self.budget = budget }
    deinit { budget.release(data.count) }
}

/// Go supplies complete JSON notifications. A bounded queue never blocks Go on
/// an actor: overflow closes this watch and the owner resubscribes with a snapshot.
final class MessageReader: @unchecked Sendable {
    let messages: AsyncThrowingStream<IPNMessage, Error>
    private let continuation: AsyncThrowingStream<IPNMessage, Error>.Continuation
    private let lock = NSLock()
    private let budget: IPNMessageBudget
    private let startupTimeout: TimeInterval
    private var operation: InProcessLocalAPIOperation?
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var terminalError: Error?
    private var started = false
    private var trace: WatchStartupTrace?
    private var receivedFirstMessage = false

    init(startupTimeout: TimeInterval = 10, maximumQueuedBytes: Int = 32 * 1024 * 1024) {
        self.startupTimeout = startupTimeout
        budget = IPNMessageBudget(limit: maximumQueuedBytes)
        var captured: AsyncThrowingStream<IPNMessage, Error>.Continuation?
        messages = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(kMaxQueueSize)) { captured = $0 }
        continuation = captured!
        continuation.onTermination = { [weak self] _ in self?.stop() }
    }
    deinit { operation?.cancel() }

    func start(node: TailscaleHandle, mask: Ipn.NotifyWatchOpt, trace: WatchStartupTrace? = nil) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { startup in
                begin(node: node, mask: mask, trace: trace, startup: startup)
            }
        } onCancel: { self.stop() }
    }

    private func begin(node: TailscaleHandle, mask: Ipn.NotifyWatchOpt, trace: WatchStartupTrace?,
                       startup: CheckedContinuation<Void, Error>) {
        let operation = InProcessLocalAPIOperation { [weak self] event in self?.receive(event) }
        lock.lock()
        if let error = terminalError { lock.unlock(); startup.resume(throwing: error); return }
        guard !started else { lock.unlock(); startup.resume(throwing: LocalAPIError.localAPIBadResponse); return }
        started = true
        startupContinuation = startup
        self.operation = operation
        self.trace = trace
        lock.unlock()
        trace?.record("native_start")
        do {
            try operation.start(node: node, method: "GET", path: "/localapi/v0/watch-ipn-bus",
                                timeout: startupTimeout, watchMask: Int64(mask.rawValue))
        } catch { finish(error) }
    }

    /// Serial native callbacks also provide the injection boundary for queue tests.
    func receive(_ event: LocalAPIEvent) {
        lock.lock()
        guard terminalError == nil else { lock.unlock(); return }
        switch event {
        case .headers(let status):
            guard status == 200 else {
                lock.unlock()
                finish(LocalAPIError.localAPIStatusError(status: status, body: ""))
                return
            }
            trace?.record("watch_accepted")
            let startup = startupContinuation
            startupContinuation = nil
            lock.unlock()
            startup?.resume()
        case .data(let data):
            guard budget.reserve(data.count) else { lock.unlock(); finish(MessageQueueError.queueCongested); return }
            if !receivedFirstMessage { receivedFirstMessage = true; trace?.record("first_message") }
            let message = IPNMessage(data: data, budget: budget)
            lock.unlock()
            switch continuation.yield(message) {
            case .enqueued: break
            case .dropped: finish(MessageQueueError.queueCongested)
            case .terminated: stop()
            @unknown default: finish(MessageQueueError.queueCongested)
            }
        case .finished(let result):
            lock.unlock()
            switch result {
            case .success: finish(MessageQueueError.unexpectedEndOfStream)
            case .failure(let error): finish(error)
            }
        }
    }

    func stop() { finish(CancellationError()) }

    private func finish(_ error: Error) {
        lock.lock()
        guard terminalError == nil else { lock.unlock(); return }
        terminalError = error
        let startup = startupContinuation
        startupContinuation = nil
        let operation = self.operation
        self.operation = nil
        let trace = self.trace
        lock.unlock()
        trace?.record(startup == nil ? "watch_finished" : "startup_failed")
        startup?.resume(throwing: error)
        continuation.finish(throwing: error)
        operation?.cancel()
    }
}
