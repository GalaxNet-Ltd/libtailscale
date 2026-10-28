// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

let kLocalAPIPath = "/localapi/v0/"

/// LocalAPIError enumerates the various errors that may be returned when making requests
/// to localAPI.
public enum LocalAPIError: Error, LocalizedError {
    case localAPIBadResponse
    case localAPIStatusError(status: Int, body: String)
    case localAPIURLRequestError
    case localAPIBugReportError
    case localAPIJSONEncodeError
}

public actor LocalAPIClient {
    enum HTTPMethod: String {
        case GET
        case POST
        case PATCH
        case PUT
        case DELETE
    }

    enum LocalAPIEndpoint: String {
        case prefs = "prefs"
        case start = "start"
        case loginInteractive = "login-interactive"
        case resetAuth = "reset-auth"
        case logout = "logout"
        case profiles = "profiles"
        case profilesCurrent = "profiles/current"
        case status = "status"
        case ping = "ping"
        case watchIPNBus = "watch-ipn-bus"
    }

    public enum PingType: String, Sendable {
        case disco
    }

    /// The local node that will be handling our localAPI requests.
    let node: TailscaleNode
    
    let logger: LogSink?

    public init(localNode: TailscaleNode, logger: LogSink?) {
        self.node = localNode
        self.logger = logger
    }


    // MARK: - IPN Bus

    /// watchIPNBus subscribes to the IPN notification bus.   This is the primary mechanism that should be implemented for observing
    /// changes to the state of the tailnet.  This uses the Go in-process LocalClient and feeds events to the consumer, via the processor.
    /// For large tailnets, or tailnets with large numbers of ephemeral devices, it is recommended that you always pass the rateLimitNetmaps
    /// option.  Netap updates may be large and frequent and the resources required to parse the incoming JSON are non-trivial..  The
    /// rateLimitNetmaps option will limit netmap updates to roughly one ever 3 seconds.
    ///
    /// You may spawn multiple bus watchers, but a single application-wide watcher with the full set of opts will often suffice.
    ///
    /// - Parameters:
    ///   - mask: a mask indicating the events we wish to observe
    ///   - consumer: an actor implementing MessageConsumer to which incoming events will be sent
    /// - Returns: The MessageProcessor handling the incoming event stream.  This should be destroyed/stopped when the caller
    ///            wishes to unsubscribe from the event stream.
    public func watchIPNBus(mask: Ipn.NotifyWatchOpt, consumer: MessageConsumer) async throws -> MessageProcessor {
        guard let handle = node.tailscale else { throw TailscaleError.badInterfaceHandle }
        let messageProcessor = await MessageProcessor(consumer: consumer, logger: logger)
        try await messageProcessor.start(node: handle, mask: mask)
        return messageProcessor
    }

    // MARK: - Prefs

    /// getPrefs returns the Ipn.Prefs for the current user
    public func getPrefs() async throws -> Ipn.Prefs {
        let result =  await doSimpleAPIRequest(
            endpoint: .prefs,
            method: .GET,
            resultTransformer: jsonDecodeTransformer(Ipn.Prefs.self))

        switch result {
        case .success(let retVal):
            return retVal
        case .failure(let error):
            logger?.log("Failed to getPrefs: \(error)")
            throw error
        }
    }

    /// editPrefs submits a request to edit the current users prefs using the given mask
    @discardableResult
    public func editPrefs(mask: Ipn.MaskedPrefs) async throws -> Ipn.Prefs {
        let result = await doJSONAPIRequest(
            endpoint: .prefs,
            method: .PATCH,
            bodyAsJSON: mask,
            resultTransformer: jsonDecodeTransformer(Ipn.Prefs.self))

        switch result {
        case .success(let retVal):
            return retVal
        case .failure(let error):
            logger?.log("Failed to editPrefs: \(error)")
            throw error
        }
    }

    // NOTE:- The Account Management and Profiles APIs are not yet fully supported
    //        via TailscaleKit.   Use with caution.  These may disappear in future
    //        versions but are included for those that wish to experiment with
    //        browser based auth and multi-user environments.
    //
    // See TailscaleNode for most of the equivalent functionality.

    // MARK: - Account Management

    public func start(options: Ipn.Options) async throws {
        let error = await doJSONAPIRequest(
            endpoint: .start,
            method: .POST,
            bodyAsJSON: options,
            resultTransformer: errorTransformer)

        if let error { throw error }
    }

    public func startLoginInteractive() async throws {
        let error = await doSimpleAPIRequest(
            endpoint: .loginInteractive,
            method: .POST,
            resultTransformer: errorTransformer)

        if let error { throw error }
    }

    public func resetAuth() async throws {
        let error = await doSimpleAPIRequest(
            endpoint: .resetAuth,
            method: .POST,
            resultTransformer: errorTransformer)

        if let error { throw error }
    }

    public func logout() async throws {
        let error = await doSimpleAPIRequest(
            endpoint: .logout,
            method: .POST,
            resultTransformer: errorTransformer)

        if let error { throw error }
    }

    // MARK: - Profiles

    public func profiles() async throws -> [IpnLocal.LoginProfile] {
        let result = await doSimpleAPIRequest(
            endpoint: .profiles,
            path: "", // Important, we need the trailing /
            method: .GET,
            resultTransformer: jsonDecodeTransformer([IpnLocal.LoginProfile].self))

        switch result {
        case .success(let result):  return result
        case .failure(let error):  throw error
        }
    }

    public func currentProfile() async throws -> IpnLocal.LoginProfile {
        let result = await doSimpleAPIRequest(
            endpoint: .profilesCurrent,
            method: .GET,
            resultTransformer: jsonDecodeTransformer(IpnLocal.LoginProfile.self))

        switch result {
        case .success(let result):  return result
        case .failure(let error):  throw error
        }
    }

    public func addProfile() async throws {
        let error = await doSimpleAPIRequest(
            endpoint: .profiles,
            path: "", // Important, we need the trailing /
            method: .PUT,
            resultTransformer: errorTransformer)

        if let error {
            logger?.log("Failed to add profile: \(error)")
            throw error
        }
    }

    public func switchProfile(profileID: String) async throws {
        let error = await  doSimpleAPIRequest(
            endpoint: .profiles,
            path: profileID,
            method: .POST,
            resultTransformer: errorTransformer)

        if let error {
            logger?.log("Failed to switch profile: \(error)")
            throw error
        }
    }

    public func deleteProfile(profileID: String) async throws {
        let error = await doSimpleAPIRequest(
            endpoint: .profiles,
            path: profileID,
            method: .DELETE,
            resultTransformer: errorTransformer)

        if let error {
            logger?.log("Failed to delete profile: \(error)")
            throw error
        }
    }

    // MARK: - Status

    /// backendStatus returns the current status of the backend.
    ///
    /// The majority of the information this returns can be observed using watchIPNBus.
    public func backendStatus() async throws -> IpnState.Status {
        let result =  await doSimpleAPIRequest(
            endpoint: .status,
            method: .GET,
            resultTransformer: jsonDecodeTransformer(IpnState.Status.self))

        switch result {
        case .success(let result):  return result
        case .failure(let error):  throw error
        }
    }

    public func ping(
        ip: String,
        type: PingType = .disco,
        timeoutInterval: TimeInterval = 2
    ) async throws -> IpnState.PingResult {
        let params = [
            URLQueryItem(name: "ip", value: ip),
            URLQueryItem(name: "type", value: type.rawValue),
        ]
        let result = await doSimpleAPIRequest(
            endpoint: .ping,
            params: params,
            method: .POST,
            timeoutInterval: timeoutInterval,
            resultTransformer: jsonDecodeTransformer(IpnState.PingResult.self))

        switch result {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    // MARK: - Requests

    private func doJSONAPIRequest<BodyT: Codable, ResultT: Sendable>(
        endpoint: LocalAPIEndpoint,
        path: String? = nil,
        method: HTTPMethod,
        bodyAsJSON: BodyT,
        timeoutInterval: TimeInterval = 60,
        resultTransformer: @escaping (_ result: Result<Data, Error>) -> ResultT
    ) async -> ResultT {
        do {
            let body = try JSONEncoder().encode(bodyAsJSON)
            return await doSimpleAPIRequest(endpoint: endpoint, path: path, method: method,
                                            body: body, timeoutInterval: timeoutInterval,
                                            resultTransformer: resultTransformer)
        } catch {
            return resultTransformer(.failure(LocalAPIError.localAPIJSONEncodeError))
        }
    }

    private func doSimpleAPIRequest<T: Sendable>(
        endpoint: LocalAPIEndpoint,
        path: String? = nil,
        params: [URLQueryItem]? = nil,
        method: HTTPMethod,
        body: Data? = nil,
        timeoutInterval: TimeInterval = 60,
        resultTransformer: @escaping (_ result: Result<Data, Error>) -> T
    ) async -> T {
        do {
            guard let handle = node.tailscale else { throw TailscaleError.badInterfaceHandle }
            var components = URLComponents()
            components.path = kLocalAPIPath + endpoint.rawValue + (path.map { "/" + $0 } ?? "")
            components.queryItems = params
            guard let requestPath = components.string else { throw LocalAPIError.localAPIURLRequestError }
            let response = try await InProcessLocalAPIOperation.request(
                node: handle, method: method.rawValue, path: requestPath, body: body, timeout: timeoutInterval
            )
            guard response.status < 300 else {
                let error = try? JSONDecoder().decode(GoError.self, from: response.body)
                throw LocalAPIError.localAPIStatusError(status: response.status,
                    body: error?.Error ?? String(data: response.body, encoding: .utf8) ?? "")
            }
            return resultTransformer(.success(response.body))
        } catch {
            return resultTransformer(.failure(error))
        }
    }

    // MARK: - Transformers

    private func errorTransformer(result: Result<Data, Error>) -> Error? {
        switch result {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    private func jsonDecodeTransformer<T: Decodable>(_ type: T.Type) -> (_ result: Result<Data, Error>) -> Result<T, Error> {
        return { result in
            switch result {
            case .success(let data):
                do {
                    return .success(try JSONDecoder().decode(T.self, from: data))
                } catch {
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        }
    }
}
