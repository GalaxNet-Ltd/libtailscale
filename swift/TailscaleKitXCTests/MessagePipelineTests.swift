// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import XCTest
@testable import TailscaleKit

final class MessagePipelineTests: XCTestCase, @unchecked Sendable {
    func testCompleteLineIsDeliveredBeforeTrailingPartialLineCompletes() async throws {
        let reader = MessageReader()
        let firstLine = expectation(description: "Complete line arrives without waiting for the partial line")
        let twoLines = expectation(description: "Both completed lines arrive")
        twoLines.expectedFulfillmentCount = 2
        let probe = LineProbe(firstLine: firstLine, eachLine: twoLines)
        let task = collect(reader, into: probe)
        defer { task.cancel(); reader.stop() }

        await reader.receiveData(Data("first\nsec".utf8))
        guard await completed(firstLine) else { return }
        let firstSnapshot = await probe.lines
        XCTAssertEqual(firstSnapshot, ["first"])

        await reader.receiveData(Data("ond\n".utf8))
        guard await completed(twoLines) else { return }
        let finalSnapshot = await probe.lines
        XCTAssertEqual(finalSnapshot, ["first", "second"])
    }

    func testOneLineCanSpanMultipleHTTPChunks() async {
        let reader = MessageReader()
        let received = expectation(description: "Fragmented line is reconstructed")
        let probe = LineProbe(eachLine: received)
        let task = collect(reader, into: probe)
        defer { task.cancel(); reader.stop() }

        await reader.receiveData(Data())
        await reader.receiveData(Data("{\"Sta".utf8))
        await reader.receiveData(Data("te\":6}".utf8))
        await reader.receiveData(Data("\n".utf8))
        guard await completed(received) else { return }
        let lines = await probe.lines
        XCTAssertEqual(lines, ["{\"State\":6}"])
    }

    func testMultipleLinesInOneChunkPreserveFIFOAndIgnoreEmptyLines() async {
        let reader = MessageReader()
        let received = expectation(description: "All complete nonempty lines arrive")
        received.expectedFulfillmentCount = 3
        let probe = LineProbe(eachLine: received)
        let task = collect(reader, into: probe)
        defer { task.cancel(); reader.stop() }

        await reader.receiveData(Data("\nfirst\n\nsecond\nthird\n".utf8))
        guard await completed(received) else { return }
        let lines = await probe.lines
        XCTAssertEqual(lines, ["first", "second", "third"])
    }

    func testOverflowPreservesAcceptedFIFOThenReportsCongestion() async {
        let reader = MessageReader()
        defer { reader.stop() }
        let input = (0...kMaxQueueSize).map { "line-\($0)\n" }.joined()
        // Fill the bounded stream before starting a consumer, so overflow does
        // not depend on scheduling or a deliberately slow network connection.
        await reader.receiveData(Data(input.utf8))
        await reader.receiveData(Data("after-overflow\n".utf8))

        let finished = expectation(description: "Overflow finishes after the accepted messages")
        let probe = LineProbe(finished: finished)
        let task = collect(reader, into: probe)
        defer { task.cancel() }
        guard await completed(finished) else { return }
        let lines = await probe.lines
        let failure = await probe.failure
        XCTAssertEqual(lines, (0..<kMaxQueueSize).map { "line-\($0)" })
        XCTAssertEqual(failure, .congested)
    }

    func testStopFinishesAnIdleStreamAndIsIdempotent() async {
        let reader = MessageReader()
        let finished = expectation(description: "Stopping unblocks the waiting reader")
        let probe = LineProbe(finished: finished)
        let task = collect(reader, into: probe)
        defer { task.cancel(); reader.stop() }

        reader.stop()
        reader.stop()
        await reader.receiveData(Data("ignored-after-stop\n".utf8))
        guard await completed(finished) else { return }
        let lines = await probe.lines
        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(wasCancelled)
    }

    func testUnexpectedHTTPEOFReportsFailureAfterAcceptedMessages() async throws {
        let reader = MessageReader()
        let finished = expectation(description: "A clean HTTP EOF is a watch failure")
        let probe = LineProbe(finished: finished)
        let task = collect(reader, into: probe)
        defer { task.cancel(); reader.stop() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid/eof")))
        try await reader.start(request, config: watchConfiguration())

        guard await completed(finished) else { return }
        let lines = await probe.lines
        let failure = await probe.failure
        XCTAssertEqual(lines, ["{\"State\":6}"])
        XCTAssertEqual(failure, .unexpectedEnd)
    }

    func testCancellingHTTPStartupResumesTheWaiterAndStopsTheRequest() async throws {
        let reader = MessageReader()
        let started = expectation(description: "HTTP request started without receiving headers")
        let stopped = expectation(description: "Cancelling startup stops the HTTP request")
        let finished = expectation(description: "Cancelled startup resumes its waiter")
        let path = "/pending/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: path, started: started, stopped: stopped)
        defer { WatchURLProtocol.events.remove(path: path); reader.stop() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(path)")))
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await reader.start(request, config: watchConfiguration())
                return false
            } catch {
                return error is CancellationError
            }
        }
        defer { task.cancel() }
        guard await completed(started) else { return }
        task.cancel()
        guard await completed(finished), await completed(stopped) else { return }
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
    }

    func testWatchUsesLongRequestTimeoutWithoutChangingCallerConfiguration() async throws {
        let reader = MessageReader()
        let started = expectation(description: "Watch request reaches the HTTP protocol")
        let stopped = expectation(description: "Explicit cancellation stops the long-lived watch")
        let finished = expectation(description: "Cancelled watch startup resumes")
        let path = "/timeout-policy/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: path, started: started, stopped: stopped)
        defer { WatchURLProtocol.events.remove(path: path); reader.stop() }

        let config = watchConfiguration()
        config.timeoutIntervalForRequest = 0.25
        config.timeoutIntervalForResource = 0.5
        var shortRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(path)")))
        shortRequest.timeoutInterval = 0.125
        let request = shortRequest
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await reader.start(request, config: config)
                return false
            } catch {
                return error is CancellationError
            }
        }
        defer { task.cancel() }

        guard await completed(started) else { return }
        let intercepted = try XCTUnwrap(WatchURLProtocol.events.request(path: path))
        // Inspect the request actually handed to URLSession, rather than only
        // its configuration: an explicit request timeout can override that.
        XCTAssertEqual(intercepted.timeoutInterval, 24 * 60 * 60)
        XCTAssertTrue(intercepted.timeoutInterval.isFinite)
        XCTAssertEqual(config.timeoutIntervalForRequest, 0.25)
        XCTAssertEqual(config.timeoutIntervalForResource, 0.5)
        XCTAssertEqual(request.timeoutInterval, 0.125)

        task.cancel()
        guard await completed(finished), await completed(stopped) else { return }
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
    }

    func testStalledHTTPHeadersTimeOutAndStopTheLongLivedRequest() async throws {
        let reader = MessageReader(startupTimeoutNanoseconds: 50_000_000)
        let started = expectation(description: "Request starts but receives no HTTP headers")
        let stopped = expectation(description: "Header deadline stops the request")
        let finished = expectation(description: "Header deadline resumes startup")
        let path = "/header-deadline/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: path, started: started, stopped: stopped)
        defer { WatchURLProtocol.events.remove(path: path); reader.stop() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(path)")))
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await reader.start(request, config: watchConfiguration())
                return URLError.Code?.none
            } catch {
                return (error as? URLError)?.code
            }
        }
        defer { task.cancel() }

        guard await completed(started), await completed(finished), await completed(stopped) else { return }
        let errorCode = await task.value
        XCTAssertEqual(errorCode, .timedOut)
    }

    func testAcceptedHeadersCancelStartupDeadlineWhileIdleWatchRemainsOpen() async throws {
        // Allow ordinary URLSession delegate scheduling; this case verifies
        // expiry after headers, not HTTP startup speed.
        let reader = MessageReader(startupTimeoutNanoseconds: 2_000_000_000)
        let started = expectation(description: "Request receives successful HTTP headers")
        let stopped = expectation(description: "Accepted watch stops on explicit cancellation")
        let initialLine = expectation(description: "Initial event arrives")
        let twoLines = expectation(description: "Event after startup deadline still arrives")
        twoLines.expectedFulfillmentCount = 2
        let path = "/accepted-headers/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: path, started: started, stopped: stopped)
        defer { WatchURLProtocol.events.remove(path: path); reader.stop() }
        let probe = LineProbe(firstLine: initialLine, eachLine: twoLines)
        let task = collect(reader, into: probe)
        defer { task.cancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(path)")))
        try await reader.start(request, config: watchConfiguration())
        guard await completed(started), await completed(initialLine) else { return }

        // Let the injected startup deadline elapse after accepted headers,
        // then deliver another real URLProtocol data callback on the same watch.
        try await Task.sleep(nanoseconds: 2_250_000_000)
        WatchURLProtocol.events.send(Data("{\"State\":6}\n".utf8), path: path)
        guard await completed(twoLines) else { return }
        let lines = await probe.lines
        let failure = await probe.failure
        XCTAssertEqual(lines, ["{\"State\":5}", "{\"State\":6}"])
        XCTAssertNil(failure)

        reader.stop()
        guard await completed(stopped) else { return }
    }

    func testProcessorAwaitsEachConsumerBeforeDeliveringTheNextState() async {
        let firstEntered = expectation(description: "First state is suspended in the consumer")
        let overtookFirst = expectation(description: "Second state must not overtake the suspended first state")
        overtookFirst.isInverted = true
        let received = expectation(description: "Both states complete")
        received.expectedFulfillmentCount = 2
        let consumer = ConsumerProbe(eachNotification: received, firstEntered: firstEntered,
                                     overtookFirst: overtookFirst)
        let processor = await MessageProcessor(consumer: consumer, logger: nil)
        defer { processor.cancel(); Task { await consumer.releaseFirst() } }
        processor.startProcessingMessages()

        await processor.reader.receiveData(notification(id: 0, state: .Starting))
        guard await completed(firstEntered) else { return }
        await processor.reader.receiveData(notification(id: 1, state: .Running))
        await fulfillment(of: [overtookFirst], timeout: 0.1)
        await consumer.releaseFirst()
        guard await completed(received) else { return }
        let states = await consumer.completedStates
        XCTAssertEqual(states, [.Starting, .Running])
    }

    func testBufferedBurstDrainsWithoutAOneHundredMillisecondDelayPerEvent() async {
        let count = 16
        let firstEntered = expectation(description: "First notification holds the consumer")
        let received = expectation(description: "The buffered burst drains promptly")
        received.expectedFulfillmentCount = count
        let consumer = ConsumerProbe(eachNotification: received, firstEntered: firstEntered)
        let processor = await MessageProcessor(consumer: consumer, logger: nil)
        defer { processor.cancel(); Task { await consumer.releaseFirst() } }
        processor.startProcessingMessages()
        await processor.reader.receiveData(notification(id: 0))
        guard await completed(firstEntered) else { return }

        for id in 1..<count {
            await processor.reader.receiveData(notification(id: id))
        }
        await consumer.releaseFirst()
        // The old per-chunk 100 ms polling would need at least 1.5 seconds for
        // this queued burst; this budget allows ordinary test-runner jitter.
        guard await completed(received, timeout: 0.75) else { return }
        let identifiers = await consumer.completedIdentifiers
        XCTAssertEqual(identifiers, (0..<count).map(String.init))
    }

    func testMalformedJSONFailsTheWatchInsteadOfSkippingAPossibleStateChange() async {
        let failed = expectation(description: "Malformed state fails the watcher")
        let consumer = ConsumerProbe(errorReceived: failed)
        let processor = await MessageProcessor(consumer: consumer, logger: nil)
        defer { processor.cancel() }
        processor.startProcessingMessages()

        await processor.reader.receiveData(Data("invalid-json\n".utf8) + notification(id: 0, state: .Running))
        guard await completed(failed) else { return }
        let states = await consumer.completedStates
        let errors = await consumer.errors
        XCTAssertTrue(states.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    func testCancellationStopsQueuedNotificationsAndDoesNotReportAnError() async {
        let firstEntered = expectation(description: "Consumer is suspended on the first event")
        let cancelledDelivery = expectation(description: "The suspended delivery observes cancellation")
        let consumer = ConsumerProbe(firstEntered: firstEntered, cancelledDelivery: cancelledDelivery)
        let processor = await MessageProcessor(consumer: consumer, logger: nil)
        defer { processor.cancel(); Task { await consumer.releaseFirst() } }
        processor.startProcessingMessages()
        await processor.reader.receiveData(notification(id: 0))
        guard await completed(firstEntered) else { return }
        await processor.reader.receiveData(notification(id: 1))

        processor.cancel()
        processor.cancel()
        await consumer.releaseFirst()
        guard await completed(cancelledDelivery) else { return }
        let identifiers = await consumer.completedIdentifiers
        let errors = await consumer.errors
        XCTAssertTrue(identifiers.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    func testReplacingLiveWatchStopsOldHTTPWhileNewWatchDeliversInOrder() async throws {
        let oldStarted = expectation(description: "Old HTTP watch starts")
        let oldStopped = expectation(description: "Replacing the watch stops its HTTP request")
        let oldEntered = expectation(description: "Old consumer suspends on its initial HTTP event")
        let oldCancelled = expectation(description: "Old suspended notification observes cancellation")
        let oldConsumer = ConsumerProbe(firstEntered: oldEntered, cancelledDelivery: oldCancelled)
        let oldProcessor = await MessageProcessor(consumer: oldConsumer, logger: nil)
        let oldPath = "/accepted-headers/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: oldPath, started: oldStarted, stopped: oldStopped)

        let newStarted = expectation(description: "Replacement HTTP watch starts independently")
        let newStopped = expectation(description: "Replacement HTTP watch stops on cleanup")
        let newReceived = expectation(description: "Replacement delivers its initial state and two updates")
        newReceived.expectedFulfillmentCount = 3
        let newConsumer = ConsumerProbe(eachNotification: newReceived)
        let newProcessor = await MessageProcessor(consumer: newConsumer, logger: nil)
        let newPath = "/accepted-headers/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: newPath, started: newStarted, stopped: newStopped)
        defer {
            oldProcessor.cancel(); newProcessor.cancel()
            Task { await oldConsumer.releaseFirst() }
            WatchURLProtocol.events.remove(path: oldPath)
            WatchURLProtocol.events.remove(path: newPath)
        }

        let oldRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(oldPath)")))
        try await oldProcessor.start(oldRequest, config: watchConfiguration())
        guard await completed(oldStarted), await completed(oldEntered) else { return }

        let partial = notification(id: 11, state: .Stopped)
        let split = partial.count / 2
        // HTTP supplies the initial event and verifies actual request teardown.
        // Inject queued bytes through the framer to establish a deterministic
        // complete-message/partial-message backlog while delivery is suspended.
        await oldProcessor.reader.receiveData(notification(id: 10) + Data(partial.prefix(split)))
        oldProcessor.cancel()

        let newRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(newPath)")))
        try await newProcessor.start(newRequest, config: watchConfiguration())
        guard await completed(newStarted), await completed(oldStopped) else { return }
        WatchURLProtocol.events.send(notification(id: 20) + notification(id: 21, state: .Stopped), path: newPath)
        guard await completed(newReceived) else { return }

        // Do not ask URLProtocol to deliver callbacks after stopLoading. This
        // injection checks the reader's own late-byte rejection boundary.
        await oldProcessor.reader.receiveData(Data(partial.dropFirst(split)) + notification(id: 12))
        await oldConsumer.releaseFirst()
        guard await completed(oldCancelled) else { return }
        let oldIdentifiers = await oldConsumer.completedIdentifiers
        let oldErrors = await oldConsumer.errors
        let newIdentifiers = await newConsumer.completedIdentifiers
        let newStates = await newConsumer.completedStates
        let newErrors = await newConsumer.errors
        XCTAssertTrue(oldIdentifiers.isEmpty)
        XCTAssertTrue(oldErrors.isEmpty)
        XCTAssertEqual(newIdentifiers, ["", "20", "21"])
        XCTAssertEqual(newStates, [.Starting, .Running, .Stopped])
        XCTAssertTrue(newErrors.isEmpty)
        newProcessor.cancel()
        guard await completed(newStopped) else { return }
    }

    func testCancellingPendingWatchStartupDoesNotBlockReplacementWatch() async throws {
        let oldStarted = expectation(description: "Old HTTP startup waits for headers")
        let oldStopped = expectation(description: "Cancelling the old processor stops its pending request")
        let oldFinished = expectation(description: "Old processor startup resumes with cancellation")
        let oldConsumer = ConsumerProbe()
        let oldProcessor = await MessageProcessor(consumer: oldConsumer, logger: nil)
        let oldPath = "/pending/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: oldPath, started: oldStarted, stopped: oldStopped)

        let newStarted = expectation(description: "Replacement starts without waiting for old headers")
        let newStopped = expectation(description: "Replacement stops on explicit cancellation")
        let newReceived = expectation(description: "Replacement delivers its initial state and update")
        newReceived.expectedFulfillmentCount = 2
        let newConsumer = ConsumerProbe(eachNotification: newReceived)
        let newProcessor = await MessageProcessor(consumer: newConsumer, logger: nil)
        let newPath = "/accepted-headers/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: newPath, started: newStarted, stopped: newStopped)
        defer {
            oldProcessor.cancel(); newProcessor.cancel()
            WatchURLProtocol.events.remove(path: oldPath)
            WatchURLProtocol.events.remove(path: newPath)
        }

        let oldRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(oldPath)")))
        let startup = Task {
            defer { oldFinished.fulfill() }
            do {
                try await oldProcessor.start(oldRequest, config: watchConfiguration())
                return false
            } catch {
                return error is CancellationError
            }
        }
        defer { startup.cancel() }
        guard await completed(oldStarted) else { return }
        oldProcessor.cancel()

        let newRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(newPath)")))
        try await newProcessor.start(newRequest, config: watchConfiguration())
        guard await completed(newStarted) else { return }
        WatchURLProtocol.events.send(notification(id: 30), path: newPath)
        guard await completed(newReceived), await completed(oldFinished), await completed(oldStopped) else { return }
        let startupWasCancelled = await startup.value
        let oldIdentifiers = await oldConsumer.completedIdentifiers
        let oldErrors = await oldConsumer.errors
        let newIdentifiers = await newConsumer.completedIdentifiers
        let newStates = await newConsumer.completedStates
        let newErrors = await newConsumer.errors
        XCTAssertTrue(startupWasCancelled)
        XCTAssertTrue(oldIdentifiers.isEmpty)
        XCTAssertTrue(oldErrors.isEmpty)
        XCTAssertEqual(newIdentifiers, ["", "30"])
        XCTAssertEqual(newStates, [.Starting, .Running])
        XCTAssertTrue(newErrors.isEmpty)
        newProcessor.cancel()
        guard await completed(newStopped) else { return }
    }

    func testReleasingProcessorCancelsItsWorkerWithoutExplicitCancellation() async {
        let firstEntered = expectation(description: "Worker reaches its consumer")
        let cancelledDelivery = expectation(description: "Deallocation cancels the suspended worker")
        let consumer = ConsumerProbe(firstEntered: firstEntered, cancelledDelivery: cancelledDelivery)
        var processor: MessageProcessor? = await MessageProcessor(consumer: consumer, logger: nil)
        defer { processor?.cancel(); Task { await consumer.releaseFirst() } }
        weak var weakProcessor = processor
        let reader = processor!.reader
        processor?.startProcessingMessages()
        await reader.receiveData(notification(id: 0))
        guard await completed(firstEntered) else { processor?.cancel(); return }

        processor = nil
        XCTAssertNil(weakProcessor, "The processing task must not retain its MessageProcessor")
        await consumer.releaseFirst()
        guard await completed(cancelledDelivery) else { return }
        let identifiers = await consumer.completedIdentifiers
        XCTAssertTrue(identifiers.isEmpty)
    }

    func testStartupTraceSeparatesHTTPAcceptanceFromSuspendedConsumerAndExcludesPayloads() async throws {
        let started = expectation(description: "HTTP headers and first event arrive")
        let stopped = expectation(description: "Traced request is cancelled")
        let entered = expectation(description: "First consumer delivery is suspended")
        let delivered = expectation(description: "First consumer delivery completes")
        let received = expectation(description: "Both notifications complete")
        received.expectedFulfillmentCount = 2
        let logger = StartupLogProbe(firstDelivery: delivered)
        let consumer = ConsumerProbe(eachNotification: received, firstEntered: entered)
        let processor = await MessageProcessor(consumer: consumer, logger: logger)
        let path = "/accepted-headers/\(UUID().uuidString)"
        WatchURLProtocol.events.register(path: path, started: started, stopped: stopped)
        defer {
            WatchURLProtocol.events.remove(path: path)
            processor.cancel()
            Task { await consumer.releaseFirst() }
        }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://ipn-watch.invalid\(path)")))
        request.setValue("secret-authorization", forHTTPHeaderField: "Authorization")
        try await processor.start(request, config: watchConfiguration())
        guard await completed(started), await completed(entered) else { return }
        let suspended = logger.startupRecords
        XCTAssertTrue(suspended.contains { $0.contains("phase=response_headers ") })
        XCTAssertTrue(suspended.contains { $0.contains("phase=first_message_decoded ") })
        XCTAssertFalse(suspended.contains { $0.contains("phase=first_message_delivered ") })

        WatchURLProtocol.events.send(Data("{\"SessionID\":\"private-event-payload\",\"State\":6}\n".utf8), path: path)
        await consumer.releaseFirst()
        guard await completed(delivered), await completed(received) else { return }
        let records = logger.startupRecords
        let fields = records.map { $0.split(separator: " ").map(String.init) }
        XCTAssertEqual(Set(fields.map { $0[3] }).count, 1, "All phases correlate to one watch")
        for phase in ["processor_start", "reader_enqueued", "reader_queue_entered", "task_resume",
                      "response_headers", "reader_start_returned", "first_body", "first_message_framed",
                      "worker_launch_requested", "worker_started", "first_message_decoded", "first_message_delivered"] {
            XCTAssertEqual(records.filter { $0.contains("phase=\(phase) ") }.count, 1, phase)
        }
        for record in fields {
            XCTAssertEqual(record.count, 6)
            XCTAssertNotNil(UInt64(record[5].replacingOccurrences(of: "elapsed_ms=", with: "")))
        }
        XCTAssertFalse(logger.allRecords.joined().contains("secret-authorization"))
        XCTAssertFalse(logger.allRecords.joined().contains("private-event-payload"))
        processor.cancel()
        guard await completed(stopped) else { return }
    }

    private func notification(id: Int, state: Ipn.State = .Running) -> Data {
        Data("{\"SessionID\":\"\(id)\",\"State\":\(state.rawValue)}\n".utf8)
    }

    private func watchConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchURLProtocol.self]
        return configuration
    }

    private func completed(_ expectation: XCTestExpectation, timeout: TimeInterval = 1) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
        return result == .completed
    }

    private func collect(_ reader: MessageReader, into probe: LineProbe) -> Task<Void, Never> {
        Task {
            do {
                for try await line in reader.messages { await probe.append(line) }
                await probe.finish(failure: nil)
            } catch {
                let failure: StreamFailure
                if error is CancellationError { failure = .cancelled }
                else if let error = error as? MessageQueueError {
                    switch error {
                    case .queueCongested: failure = .congested
                    case .unexpectedEndOfStream: failure = .unexpectedEnd
                    }
                } else { failure = .other }
                await probe.finish(failure: failure)
            }
        }
    }
}

private final class StartupLogProbe: LogSink, @unchecked Sendable {
    let logFileHandle: Int32? = nil
    private let lock = NSLock()
    private var records: [String] = []
    private let firstDelivery: XCTestExpectation

    init(firstDelivery: XCTestExpectation) { self.firstDelivery = firstDelivery }

    var allRecords: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    var startupRecords: [String] { allRecords.filter { $0.hasPrefix("IPN watch startup ") } }

    func log(_ message: String) {
        lock.lock()
        records.append(message)
        lock.unlock()
        if message.contains("phase=first_message_delivered ") { firstDelivery.fulfill() }
    }
}

private enum StreamFailure: Equatable, Sendable {
    case cancelled
    case congested
    case unexpectedEnd
    case other
}

private actor LineProbe {
    private(set) var lines: [String] = []
    private(set) var failure: StreamFailure?
    var wasCancelled: Bool { failure == .cancelled }
    private let firstLine: XCTestExpectation?
    private let eachLine: XCTestExpectation?
    private let finished: XCTestExpectation?

    init(firstLine: XCTestExpectation? = nil, eachLine: XCTestExpectation? = nil,
         finished: XCTestExpectation? = nil) {
        self.firstLine = firstLine
        self.eachLine = eachLine
        self.finished = finished
    }

    func append(_ line: Data) {
        lines.append(String(decoding: line, as: UTF8.self))
        if lines.count == 1 { firstLine?.fulfill() }
        eachLine?.fulfill()
    }

    func finish(failure: StreamFailure?) {
        self.failure = failure
        finished?.fulfill()
    }
}

private actor ConsumerProbe: MessageConsumer {
    private(set) var completedIdentifiers: [String] = []
    private(set) var completedStates: [Ipn.State] = []
    private(set) var errors: [String] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var enteredCount = 0
    private let eachNotification: XCTestExpectation?
    private let firstEntered: XCTestExpectation?
    private let overtookFirst: XCTestExpectation?
    private let cancelledDelivery: XCTestExpectation?
    private let errorReceived: XCTestExpectation?

    init(eachNotification: XCTestExpectation? = nil, firstEntered: XCTestExpectation? = nil,
         overtookFirst: XCTestExpectation? = nil, cancelledDelivery: XCTestExpectation? = nil,
         errorReceived: XCTestExpectation? = nil) {
        self.eachNotification = eachNotification
        self.firstEntered = firstEntered
        self.overtookFirst = overtookFirst
        self.cancelledDelivery = cancelledDelivery
        self.errorReceived = errorReceived
    }

    func notify(_ notify: Ipn.Notify) async {
        guard !Task.isCancelled else { return }
        enteredCount += 1
        if enteredCount == 1, let firstEntered {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                firstEntered.fulfill()
            }
        } else if firstContinuation != nil {
            overtookFirst?.fulfill()
        }
        guard !Task.isCancelled else {
            cancelledDelivery?.fulfill()
            return
        }
        completedIdentifiers.append(notify.SessionID ?? "")
        if let state = notify.State { completedStates.append(state) }
        eachNotification?.fulfill()
    }

    func error(_ error: Error) {
        guard !Task.isCancelled else { return }
        errors.append(String(describing: error))
        errorReceived?.fulfill()
    }

    func releaseFirst() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume()
    }
}

/// Handles every test watch in memory; no request reaches a network endpoint.
private final class WatchURLProtocol: URLProtocol, @unchecked Sendable {
    static let events = WatchProtocolEvents()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ipn-watch.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/eof" {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"State\":6}\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else if url.path.hasPrefix("/accepted-headers/") {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"State\":5}\n".utf8))
            Self.events.started(request: request) { [weak self] data in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: data)
            }
        } else {
            Self.events.started(request: request)
        }
    }

    override func stopLoading() {
        if let path = request.url?.path { Self.events.stopped(path: path) }
    }
}

private final class WatchProtocolEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: XCTestExpectation] = [:]
    private var stops: [String: XCTestExpectation] = [:]
    private var requests: [String: URLRequest] = [:]
    private var writers: [String: @Sendable (Data) -> Void] = [:]

    func register(path: String, started: XCTestExpectation, stopped: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        starts[path] = started
        stops[path] = stopped
    }

    func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        starts.removeValue(forKey: path)
        stops.removeValue(forKey: path)
        requests.removeValue(forKey: path)
        writers.removeValue(forKey: path)
    }

    func started(request: URLRequest, writer: (@Sendable (Data) -> Void)? = nil) {
        guard let path = request.url?.path else { return }
        lock.lock()
        requests[path] = request
        writers[path] = writer
        let expectation = starts.removeValue(forKey: path)
        lock.unlock()
        expectation?.fulfill()
    }

    func request(path: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[path]
    }

    func send(_ data: Data, path: String) {
        lock.lock()
        let writer = writers[path]
        lock.unlock()
        writer?(data)
    }

    func stopped(path: String) {
        lock.lock()
        let expectation = stops.removeValue(forKey: path)
        lock.unlock()
        expectation?.fulfill()
    }
}
