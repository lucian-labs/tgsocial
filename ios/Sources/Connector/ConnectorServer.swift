// Connector — the loopback listener (CONNECTOR.md §1, §2). Mac only.
//
// `NWParameters.requiredLocalEndpoint` pinned to `127.0.0.1` is what makes "local only" a
// property of the socket rather than a promise in a comment: the listener binds
// `127.0.0.1:<port>`, not `*:<port>`, so a packet arriving on the machine's LAN address has
// nowhere to land. There is no setting that widens it and no remote mode to add one — §8 says
// adding one would need a different security model than a bearer token, and it would.
//
// Lifecycle is the other half of the contract. `stop()` cancels the listener, cancels every open
// connection, and cancels every in-flight handler task. §2: "Rotating writes a new token and
// drops all in-flight requests"; PRODUCT §2.14: turning the toggle off "stops listening
// immediately and drops in-flight requests". Both go through `stop()`.

#if targetEnvironment(macCatalyst)

import Foundation
import Network

/// Handles one parsed request. Hops to the main actor inside the router.
typealias ConnectorHandler = @Sendable (ConnectorRequest) async -> ConnectorResponse

final class ConnectorServer: @unchecked Sendable {
    enum StartFailure: Swift.Error, Equatable {
        /// PRODUCT §2.14: "A port already in use shows `That port is taken.`"
        case portTaken
        case invalidPort
        case failed(String)
    }

    /// A connection that has said nothing for this long is not a client of this bridge.
    static let readTimeout: TimeInterval = 15

    private let queue = DispatchQueue(label: "ca.lucianlabs.tgsocial.connector", qos: .userInitiated)
    private let handler: ConnectorHandler
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var boundPort: UInt16 = 0

    init(handler: @escaping ConnectorHandler) { self.handler = handler }

    /// The port actually bound. Equals the requested port, except for the ephemeral `0` the tests
    /// use — which is why this is read from the listener rather than remembered from the request.
    var port: UInt16 { lock.withLock { boundPort } }
    var isListening: Bool { lock.withLock { listener != nil } }

    /// Binds and starts listening. Returns once the listener is ready, or throws — the caller is
    /// the toggle in §2.14, and it must not turn on over a socket that never came up.
    func start(port requested: UInt16) async throws {
        stop()
        guard requested == 0 || requested >= 1 else { throw StartFailure.invalidPort }

        let parameters = NWParameters.tcp
        // The bind. Loopback, IPv4, and nothing else — not `acceptLocalOnly`, which would still
        // accept from the local link, i.e. the LAN.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: requested == 0 ? .any : (NWEndpoint.Port(rawValue: requested) ?? .any))
        // A listener that was cancelled a moment ago can still hold the port in TIME_WAIT;
        // without reuse, flipping the toggle off and on again would report "That port is taken."
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw Self.startFailure(from: error) }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self else { return }
                    self.lock.withLock { self.boundPort = listener.port?.rawValue ?? requested }
                    if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // `.waiting` on a listener means the bind did not take — an occupied port
                    // sits here for ever rather than failing, so it is treated as a failure.
                    listener.cancel()
                    if resumed.claim() { continuation.resume(throwing: Self.startFailure(from: error)) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: StartFailure.failed("cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
    }

    /// Idempotent. Every open socket and every handler task goes with it.
    func stop() {
        let (listener, connections, tasks): (NWListener?, [NWConnection], [Task<Void, Never>]) = lock.withLock {
            let l = self.listener
            let c = Array(self.connections.values)
            let t = Array(self.tasks.values)
            self.listener = nil
            self.connections = [:]
            self.tasks = [:]
            self.boundPort = 0
            return (l, c, t)
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        for task in tasks { task.cancel() }
        for connection in connections { connection.cancel() }
    }

    deinit { stop() }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data(), deadline: Date().addingTimeInterval(Self.readTimeout))
    }

    private func receive(_ connection: NWConnection, buffer: Data, deadline: Date) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil { self.close(connection); return }
            var next = buffer
            if let chunk, !chunk.isEmpty { next.append(chunk) }

            switch ConnectorHTTP.parse(next) {
            case .request(let request):
                self.serve(request, on: connection)
            case .malformed(let why):
                self.send(.error(.badRequest(why)), on: connection)
            case .incomplete:
                if isComplete { self.close(connection); return }
                guard Date() < deadline, next.count <= ConnectorHTTP.maxBodyBytes + ConnectorHTTP.maxHeadBytes else {
                    self.send(.error(.badRequest("request timed out")), on: connection)
                    return
                }
                self.receive(connection, buffer: next, deadline: deadline)
            }
        }
    }

    private func serve(_ request: ConnectorRequest, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let task = Task { [weak self] in
            guard let self else { return }
            let response = await self.handler(request)
            // A stop() between the dispatch and the reply drops the reply: that is what "drops
            // in-flight requests" means, and the client sees the socket close rather than a
            // response from a bridge that is supposed to be off.
            guard !Task.isCancelled else { self.close(connection); return }
            self.send(response, on: connection)
        }
        lock.withLock { tasks[id] = task }
    }

    private func send(_ response: ConnectorResponse, on connection: NWConnection) {
        connection.send(content: response.serialised(), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let task: Task<Void, Never>? = lock.withLock {
            connections.removeValue(forKey: id)
            return tasks.removeValue(forKey: id)
        }
        task?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private static func startFailure(from error: Swift.Error) -> StartFailure {
        if let nw = error as? NWError, case .posix(let code) = nw {
            switch code {
            case .EADDRINUSE, .EACCES, .EADDRNOTAVAIL: return .portTaken
            default: return .failed(String(describing: code))
            }
        }
        return .failed(String(describing: error))
    }

    /// A continuation must be resumed exactly once, and `stateUpdateHandler` can fire again after
    /// `.ready` (a listener that later fails, a cancel during start). One claim, one resume.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.withLock {
                guard !used else { return false }
                used = true
                return true
            }
        }
    }
}

#endif
