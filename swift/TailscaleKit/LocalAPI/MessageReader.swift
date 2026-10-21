// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

enum MessageQueueError: Error {
    case queueCongested
    case unexpectedEndOfStream
}

/// Bound pending notifications while the consumer is busy. Overflow requires a
/// new subscription with .initialState so no backend state is silently lost.
let kMaxQueueSize = 24

/// Immutable correlation shared across the delegate queue and consumer task.
/// Only phase names and monotonic elapsed times are logged, never HTTP data.
struct WatchStartupTrace: Sendable {
    private let logger: (any LogSink)?
    private let identifier = UUID().uuidString
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    init(logger: (any LogSink)?) {
        self.logger = logger
    }

    func record(_ phase: String) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        logger?.log("IPN watch startup id=\(identifier) phase=\(phase) elapsed_ms=\(elapsed)")
    }
}

/// Frames the IPN bus's newline-delimited JSON independently of HTTP chunks.
final class MessageReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// A quiet notification bus is healthy. Bound its HTTP lifetime to one day
    /// instead of inheriting URLSession's 60-second inactivity timeout. The
    /// owning processor still stops it immediately through explicit cancellation.
    static let watchTimeoutInterval: TimeInterval = 24 * 60 * 60

    let messages: AsyncThrowingStream<Data, Error>

    /// URLSession invokes all delegate methods on this serial queue. Other
    /// entry points enqueue their state changes onto the same queue.
    private let workQueue = OperationQueue()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var buffer = Data()
    private var scannedByteCount = 0
    private var ipnWatchSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private let startupTimeoutNanoseconds: UInt64
    private var startupDeadlineTask: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var startupTrace: WatchStartupTrace?
    private var receivedFirstBody = false
    private var framedFirstMessage = false

    init(startupTimeoutNanoseconds: UInt64 = 60_000_000_000) {
        self.startupTimeoutNanoseconds = startupTimeoutNanoseconds
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        messages = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(kMaxQueueSize)) {
            streamContinuation = $0
        }
        continuation = streamContinuation!
        super.init()
        workQueue.maxConcurrentOperationCount = 1
        workQueue.name = "io.tailscale.ipn.MessageReader.workQueue"
        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }
    }

    /// Stop both the HTTP subscription and any consumer waiting for a message.
    /// Repeated calls are harmless, including before HTTP startup completes.
    func stop() {
        workQueue.addOperation {
            self.finish(throwing: CancellationError())
        }
    }

    /// Wait only for the local HTTP subscription to be accepted. Backend
    /// readiness continues to come from the ordered IPN notifications.
    func start(_ request: URLRequest, config: URLSessionConfiguration,
               trace: WatchStartupTrace? = nil) async throws {
        trace?.record("reader_enqueued")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (startup: CheckedContinuation<Void, Error>) in
                workQueue.addOperation {
                    guard !self.finished else {
                        startup.resume(throwing: CancellationError())
                        return
                    }
                    guard !self.started else {
                        startup.resume(throwing: LocalAPIError.localAPIBadResponse)
                        return
                    }
                    self.started = true
                    self.startupTrace = trace
                    trace?.record("reader_queue_entered")
                    self.startupContinuation = startup
                    self.startStartupDeadline()
                    // Keep this policy local to the streaming watch. Preserve
                    // proxy/auth configuration without changing ordinary API
                    // request timeouts on the caller's configuration instance.
                    let watchConfig = config.copy() as! URLSessionConfiguration
                    watchConfig.timeoutIntervalForRequest = Self.watchTimeoutInterval
                    watchConfig.timeoutIntervalForResource = Self.watchTimeoutInterval
                    trace?.record("configuration_waits_\(watchConfig.waitsForConnectivity)_proxy_\(watchConfig.connectionProxyDictionary?.isEmpty == false)")
                    var watchRequest = request
                    watchRequest.timeoutInterval = Self.watchTimeoutInterval
                    let session = URLSession(configuration: watchConfig,
                                             delegate: self,
                                             delegateQueue: self.workQueue)
                    self.ipnWatchSession = session
                    let task = session.dataTask(with: watchRequest)
                    self.dataTask = task
                    trace?.record("task_resume")
                    task.resume()
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard session === ipnWatchSession, !finished else { return }
        // A watch is long-lived; even a clean EOF requires resubscription.
        finish(throwing: error ?? MessageQueueError.unexpectedEndOfStream)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard session === ipnWatchSession, !finished else {
            completionHandler(.cancel)
            return
        }
        startupTrace?.record("response_headers")
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: LocalAPIError.localAPIBadResponse)
            return
        }
        guard httpResponse.statusCode < 300 else {
            completionHandler(.cancel)
            finish(throwing: LocalAPIError.localAPIStatusError(status: httpResponse.statusCode, body: ""))
            return
        }

        let startup = startupContinuation
        startupContinuation = nil
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        startup?.resume()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard session === ipnWatchSession else { return }
        if !finished, !data.isEmpty, !receivedFirstBody {
            receivedFirstBody = true
            startupTrace?.record("first_body")
        }
        // Already on workQueue: deliver without another queue hop or polling.
        frameMessages(in: data)
    }

    /// Feed bytes through the same framing path without a network dependency.
    func receiveData(_ data: Data) async {
        await withCheckedContinuation { completion in
            workQueue.addOperation {
                self.frameMessages(in: data)
                completion.resume()
            }
        }
    }

    private func frameMessages(in data: Data) {
        guard !finished, !data.isEmpty else { return }
        buffer.append(data)
        var messageStart = buffer.startIndex
        var searchStart = buffer.index(buffer.startIndex, offsetBy: scannedByteCount)
        while let newline = buffer[searchStart...].firstIndex(of: kJsonNewline) {
            let nextStart = buffer.index(after: newline)
            if newline != messageStart {
                let message = Data(buffer[messageStart..<newline])
                if !framedFirstMessage {
                    framedFirstMessage = true
                    startupTrace?.record("first_message_framed")
                }
                switch continuation.yield(message) {
                case .enqueued:
                    break
                case .dropped:
                    finish(throwing: MessageQueueError.queueCongested)
                    return
                case .terminated:
                    finish(throwing: CancellationError())
                    return
                @unknown default:
                    finish(throwing: MessageQueueError.queueCongested)
                    return
                }
            }
            messageStart = nextStart
            searchStart = nextStart
        }
        if messageStart != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<messageStart)
        }
        // Previously inspected partial bytes cannot acquire a delimiter when
        // the next HTTP chunk arrives, so scan only newly appended bytes.
        scannedByteCount = buffer.count
    }

    /// The long stream timeout applies only once its HTTP subscription exists.
    /// Keep stalled headers bounded independently so the owner can retry them.
    private func startStartupDeadline() {
        let timeout = startupTimeoutNanoseconds
        startupDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            self?.workQueue.addOperation { [weak self] in
                guard let self, self.startupContinuation != nil else { return }
                self.finish(throwing: URLError(.timedOut))
            }
        }
    }

    /// Called only on workQueue. Finishing the bounded stream preserves queued
    /// messages before its error, while cancellation stops its worker promptly.
    private func finish(throwing error: Error) {
        guard !finished else { return }
        finished = true
        // A single terminal record also identifies startup failures/cancellation.
        startupTrace?.record(startupContinuation == nil ? "watch_finished" : "startup_failed")
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        buffer.removeAll()
        scannedByteCount = 0
        let startup = startupContinuation
        startupContinuation = nil
        startup?.resume(throwing: error)
        continuation.finish(throwing: error)
        dataTask?.cancel()
        dataTask = nil
        ipnWatchSession?.invalidateAndCancel()
        ipnWatchSession = nil
    }
}
