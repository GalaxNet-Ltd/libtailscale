// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

enum LocalAPIEvent: Sendable {
    case headers(Int)
    case data(Data)
    case finished(Result<Void, Error>)
}

struct LocalAPIResponse: Sendable {
    let status: Int
    let body: Data
}

/// The registry owns callback destinations until Go's terminal callback. Numeric
/// tokens avoid passing Swift/Go object pointers across the asynchronous C ABI.
private final class LocalAPICallbackRegistry: @unchecked Sendable {
    static let shared = LocalAPICallbackRegistry()
    private let lock = NSLock()
    private var nextToken: UInt64 = 0
    private var operations: [UInt64: InProcessLocalAPIOperation] = [:]

    func insert(_ operation: InProcessLocalAPIOperation) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextToken &+= 1
        operations[nextToken] = operation
        return nextToken
    }

    func operation(for token: UInt64, terminal: Bool) -> InProcessLocalAPIOperation? {
        lock.lock()
        defer { lock.unlock() }
        if terminal { return operations.removeValue(forKey: token) }
        return operations[token]
    }
}

/// State is protected by lock; no lock is held while calling Go or a consumer.
/// Go callbacks only copy/deliver bytes and never synchronously wait for Swift tasks.
final class InProcessLocalAPIOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (LocalAPIEvent) -> Void
    private var identifier: UInt64?
    private var started = false
    private var finished = false
    private var cancelled = false

    init(handler: @escaping @Sendable (LocalAPIEvent) -> Void) { self.handler = handler }

    func start(node: TailscaleHandle, method: String, path: String, body: Data = Data(),
               timeout: TimeInterval, watchMask: Int64 = -1) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400,
              !method.contains("\0"), !path.contains("\0") else {
            throw TailscaleError.invalidTimeout
        }
        try begin()
        let token = LocalAPICallbackRegistry.shared.insert(self)
        var nativeID: UInt64 = 0
        let result = method.withCString { methodBytes in
            path.withCString { pathBytes in
                body.withUnsafeBytes { bytes in
                    tailscale_localapi_start(node, methodBytes, pathBytes, bytes.baseAddress,
                                            bytes.count, Int32(max(1, timeout * 1_000)), watchMask,
                                            Self.callback, token, &nativeID)
                }
            }
        }
        guard result == 0 else {
            _ = LocalAPICallbackRegistry.shared.operation(for: token, terminal: true)
            throw TailscaleError.fromPosixErrCode(result)
        }
        installIdentifier(nativeID)
    }

    private func begin() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        guard !started else { throw LocalAPIError.localAPIBadResponse }
        started = true
    }

    private func installIdentifier(_ id: UInt64) {
        lock.lock()
        identifier = id
        let shouldCancel = cancelled
        lock.unlock()
        // Cancellation or terminal delivery can race the native start returning.
        if shouldCancel { tailscale_localapi_cancel(id) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = identifier
        lock.unlock()
        deliver(.finished(.failure(CancellationError())))
        if let id { tailscale_localapi_cancel(id) }
    }

    private func deliver(_ event: LocalAPIEvent) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if case .finished = event { finished = true }
        lock.unlock()
        handler(event)
    }

    private static let callback: tailscale_localapi_callback = { token, kind, status, pointer, length in
        guard let operation = LocalAPICallbackRegistry.shared.operation(for: token, terminal: kind == 3) else { return }
        let data = pointer.map { Data(bytes: $0, count: length) } ?? Data()
        switch kind {
        case 1: operation.deliver(.headers(Int(status)))
        case 2: operation.deliver(.data(data))
        case 3:
            let result: Result<Void, Error>
            switch status {
            case 0: result = .success(())
            case ECANCELED: result = .failure(CancellationError())
            case ETIMEDOUT: result = .failure(URLError(.timedOut))
            default:
                result = .failure(TailscaleError.fromPosixErrCode(status, String(data: data, encoding: .utf8)))
            }
            operation.deliver(.finished(result))
        default: operation.cancel()
        }
    }

    static func request(node: TailscaleHandle, method: String, path: String, body: Data?,
                        timeout: TimeInterval) async throws -> LocalAPIResponse {
        let response = LocalAPIResponseWaiter()
        let operation = InProcessLocalAPIOperation { event in response.receive(event) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                response.install(continuation)
                do {
                    try operation.start(node: node, method: method, path: path, body: body ?? Data(), timeout: timeout)
                } catch {
                    response.receive(.finished(.failure(error)))
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// Cancellation may precede continuation installation, or race completion.
/// Keep one result under lock and resume the continuation exactly once.
private final class LocalAPIResponseWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalAPIResponse, Error>?
    private var result: Result<LocalAPIResponse, Error>?
    private var status: Int?
    private var body = Data()

    func install(_ continuation: CheckedContinuation<LocalAPIResponse, Error>) {
        lock.lock()
        let ready = result
        if ready == nil { self.continuation = continuation }
        lock.unlock()
        if let ready { continuation.resume(with: ready) }
    }

    func receive(_ event: LocalAPIEvent) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        switch event {
        case .headers(let status): self.status = status
        case .data(let data): body = data
        case .finished(let completion):
            result = completion.flatMap {
                guard let status else { return .failure(LocalAPIError.localAPIBadResponse) }
                return .success(LocalAPIResponse(status: status, body: body))
            }
        }
        let ready = result
        let waiter = ready == nil ? nil : continuation
        if ready != nil { continuation = nil }
        lock.unlock()
        if let ready { waiter?.resume(with: ready) }
    }
}
