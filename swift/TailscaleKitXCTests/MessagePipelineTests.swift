// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import XCTest
@testable import TailscaleKit

final class MessagePipelineTests: XCTestCase, @unchecked Sendable {
    func testOverflowPreservesAcceptedFIFOThenReportsCongestion() async {
        let reader = MessageReader()
        for id in 0...kMaxQueueSize { reader.receive(.data(Data(String(id).utf8))) }
        reader.receive(.data(Data("late".utf8)))
        var received: [String] = []
        do {
            for try await message in reader.messages { received.append(String(decoding: message.data, as: UTF8.self)) }
            XCTFail("Overflow must require a fresh snapshot")
        } catch { XCTAssertEqual(error as? MessageQueueError, .queueCongested) }
        XCTAssertEqual(received, (0..<kMaxQueueSize).map(String.init))
    }

    func testByteBudgetIncludesMessageHeldByConsumerAndReleasesAfterConsumption() async throws {
        let reader = MessageReader(maximumQueuedBytes: 8)
        reader.receive(.data(Data(repeating: 1, count: 6)))
        var iterator = reader.messages.makeAsyncIterator()
        var held = try await iterator.next()
        XCTAssertEqual(held?.data.count, 6)
        held = nil
        reader.receive(.data(Data(repeating: 2, count: 6)))
        let second = try await iterator.next()
        XCTAssertEqual(second?.data.count, 6)
        reader.receive(.data(Data(repeating: 3, count: 3)))
        do { _ = try await iterator.next(); XCTFail("Expected byte congestion") }
        catch { XCTAssertEqual(error as? MessageQueueError, .queueCongested) }
        withExtendedLifetime(second) {}
    }

    func testIdleCancellationAndUnexpectedEOF() async {
        for cancelled in [false, true] {
            let reader = MessageReader()
            if cancelled { reader.stop(); reader.stop() }
            else { reader.receive(.finished(.success(()))) }
            do {
                for try await _ in reader.messages { XCTFail("Idle stream produced data") }
                XCTFail("Expected terminal error")
            } catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? MessageQueueError, .unexpectedEndOfStream) }
            }
        }
    }

    func testInvalidNativeHandleAndPrecancelledStartupFinishPromptly() async {
        let reader = MessageReader()
        do { try await reader.start(node: -1, mask: [.initialState]); XCTFail("Invalid node succeeded") }
        catch { XCTAssertFalse(error is CancellationError) }
        let cancelled = MessageReader()
        cancelled.stop()
        do { try await cancelled.start(node: -1, mask: [.initialState]); XCTFail("Cancelled startup succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testNativeRequestsWatchReplacementAndNodeClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = try TailscaleNode(config: Configuration(hostName: "bridge-tests", path: directory.path,
            authKey: nil, controlURL: "http://127.0.0.1:1", disableLogTail: true), logger: nil)
        let nativeHandle = await node.tailscale
        let handle = try XCTUnwrap(nativeHandle)
        let response = try await InProcessLocalAPIOperation.request(node: handle, method: "GET",
            path: "/localapi/v0/status?peers=false", body: nil, timeout: 5)
        XCTAssertEqual(response.status, 200)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let missing = try await InProcessLocalAPIOperation.request(node: handle, method: "GET",
            path: "/localapi/v0/missing", body: nil, timeout: 5)
        XCTAssertEqual(missing.status, 404)
        XCTAssertFalse(missing.body.isEmpty)
        let loopback = try await node.repairExistingLoopbackIfNeeded()
        XCTAssertNil(loopback, "LocalAPI must not create the browser TCP listener")

        let first = MessageReader(startupTimeout: 1)
        try await first.start(node: handle, mask: [.initialState, .netmap])
        var firstIterator = first.messages.makeAsyncIterator()
        let initial = try await firstIterator.next()
        XCTAssertNotNil(try JSONDecoder().decode(Ipn.Notify.self, from: XCTUnwrap(initial).data).State)
        // The startup deadline must not expire an already established idle watch.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        first.stop()
        let replacement = MessageReader()
        try await replacement.start(node: handle, mask: [.initialState, .netmap])
        var replacementIterator = replacement.messages.makeAsyncIterator()
        let fresh = try await replacementIterator.next()
        XCTAssertNotNil(try JSONDecoder().decode(Ipn.Notify.self, from: XCTUnwrap(fresh).data).State)
        try await node.close()
        do {
            while try await replacementIterator.next() != nil {}
            XCTFail("Node close must fail its watch")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testNativeCancellationRacesStartupAndResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = try TailscaleNode(config: Configuration(hostName: "cancel-tests", path: directory.path,
            authKey: nil, controlURL: "http://127.0.0.1:1", disableLogTail: true), logger: nil)
        let nativeHandle = await node.tailscale
        let handle = try XCTUnwrap(nativeHandle)
        for _ in 0..<32 {
            let request = Task {
                try await InProcessLocalAPIOperation.request(node: handle, method: "GET",
                    path: "/localapi/v0/status", body: nil, timeout: 5)
            }
            request.cancel()
            request.cancel()
            do { _ = try await request.value }
            catch { XCTAssertTrue(error is CancellationError) }
            let reader = MessageReader()
            let startup = Task { try await reader.start(node: handle, mask: [.initialState]) }
            reader.stop()
            do { try await startup.value }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        try await node.close()
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

        processor.reader.receive(.data(notification(id: 0, state: .Starting)))
        guard await completed(firstEntered) else { return }
        processor.reader.receive(.data(notification(id: 1, state: .Running)))
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
        processor.reader.receive(.data(notification(id: 0)))
        guard await completed(firstEntered) else { return }

        for id in 1..<count {
            processor.reader.receive(.data(notification(id: id)))
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

        processor.reader.receive(.data(Data("invalid-json\n".utf8) + notification(id: 0, state: .Running)))
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
        processor.reader.receive(.data(notification(id: 0)))
        guard await completed(firstEntered) else { return }
        processor.reader.receive(.data(notification(id: 1)))

        processor.cancel()
        processor.cancel()
        await consumer.releaseFirst()
        guard await completed(cancelledDelivery) else { return }
        let identifiers = await consumer.completedIdentifiers
        let errors = await consumer.errors
        XCTAssertTrue(identifiers.isEmpty)
        XCTAssertTrue(errors.isEmpty)
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
        reader.receive(.data(notification(id: 0)))
        guard await completed(firstEntered) else { processor?.cancel(); return }

        processor = nil
        XCTAssertNil(weakProcessor, "The processing task must not retain its MessageProcessor")
        await consumer.releaseFirst()
        guard await completed(cancelledDelivery) else { return }
        let identifiers = await consumer.completedIdentifiers
        XCTAssertTrue(identifiers.isEmpty)
    }


    private func notification(id: Int, state: Ipn.State = .Running) -> Data {
        Data("{\"SessionID\":\"\(id)\",\"State\":\(state.rawValue)}".utf8)
    }
    private func completed(_ expectation: XCTestExpectation, timeout: TimeInterval = 1) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
        return result == .completed
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
