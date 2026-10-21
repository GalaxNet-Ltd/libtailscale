// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

let kJsonNewline = UInt8(ascii: "\n")

/// A MessageConsumer consumes incoming messages from the IPNBus and handles any
/// potential errors.
public protocol MessageConsumer: Actor {
    func notify(_ notify: Ipn.Notify) async
    func error(_ error: Error) async
}

/// Decodes and delivers IPN notifications in order, as soon as they arrive.
public class MessageProcessor: @unchecked Sendable {
    let consumer: any MessageConsumer
    let reader: MessageReader
    private let logger: LogSink?
    private let lifecycleLock = NSLock()
    private var processingTask: Task<Void, Never>?
    private var cancelled = false

    init(consumer: any MessageConsumer, logger: LogSink?) async {
        self.logger = logger
        self.consumer = consumer
        self.reader = MessageReader()
    }

    deinit {
        cancel()
    }

    func start(_ request: URLRequest, config: URLSessionConfiguration, errorHandler: (@Sendable (Error) -> Void)? = nil) async throws {
        let trace = WatchStartupTrace(logger: logger)
        trace.record("processor_start")
        logger?.log("Starting MessageProcessor for \(request.url?.absoluteString ?? "nil")")
        do {
            try await reader.start(request, config: config, trace: trace)
            try Task.checkCancellation()
            trace.record("reader_start_returned")
            startProcessingMessages(errorHandler: errorHandler, trace: trace)
        } catch {
            cancel()
            throw error
        }
    }

    /// Cancel the consumer and close the HTTP watch. The worker captures its
    /// dependencies rather than this processor, so releasing it also stops it.
    public func cancel() {
        lifecycleLock.lock()
        cancelled = true
        let task = processingTask
        processingTask = nil
        lifecycleLock.unlock()
        task?.cancel()
        reader.stop()
    }

    func startProcessingMessages(errorHandler: (@Sendable (Error) -> Void)? = nil,
                                 trace: WatchStartupTrace? = nil) {
        trace?.record("worker_launch_requested")
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !cancelled, processingTask == nil else { return }
        let consumer = consumer
        let reader = reader
        let logger = logger
        processingTask = Task {
            trace?.record("worker_started")
            logger?.log("Watching MessageReader")
            defer { logger?.log("Unwatching MessageReader") }
            let decoder = JSONDecoder()
            var deliveredFirstMessage = false
            do {
                for try await data in reader.messages {
                    try Task.checkCancellation()
                    let notify: Ipn.Notify
                    do {
                        notify = try decoder.decode(Ipn.Notify.self, from: data)
                    } catch {
                        logger?.log("Failed to decode message: \(error.localizedDescription)")
                        throw error
                    }
                    // Await each delivery rather than launching independent
                    // tasks that can reorder backend state transitions.
                    try Task.checkCancellation()
                    if !deliveredFirstMessage { trace?.record("first_message_decoded") }
                    await consumer.notify(notify)
                    if !deliveredFirstMessage {
                        deliveredFirstMessage = true
                        trace?.record("first_message_delivered")
                    }
                }
            } catch {
                reader.stop()
                guard !Task.isCancelled else { return }
                if let errorHandler {
                    errorHandler(error)
                } else {
                    await consumer.error(error)
                }
            }
        }
    }
}
