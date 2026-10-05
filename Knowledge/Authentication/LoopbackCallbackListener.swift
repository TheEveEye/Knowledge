import Foundation
import Network

@MainActor final class LoopbackCallbackListener {
    private struct Connection {
        let socket: NWConnection
        var headers = OAuthHeaderBuffer()
        var timeout: Task<Void, Never>?
    }

    let attempt: OAuthAttempt
    var onFailure: (@MainActor (AuthenticationError) -> Void)?
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, any Error>?
    private var connections: [UUID: Connection] = [:]
    private var pendingCallback: OAuthCallback?
    private var acceptedCallback = false
    private var port: UInt16?

    init(attempt: OAuthAttempt) { self.attempt = attempt }

    func start() async throws -> URL {
        guard listener == nil else { throw AuthenticationError.invalidResponse }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { @Sendable [weak self] state in
            let target = self
            Task { @MainActor in target?.stateChanged(state) }
        }
        listener.newConnectionHandler = { @Sendable [weak self] connection in
            let target = self
            Task { @MainActor in target?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func consumeCallback(bridgeURL: URL) throws -> OAuthCallback {
        try OAuthProtocol.validateBridge(bridgeURL, attemptID: attempt.bridgeID)
        guard let callback = pendingCallback else { throw AuthenticationError.invalidCallback }
        pendingCallback = nil
        return callback
    }

    func cancel() {
        let continuation = startContinuation
        startContinuation = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.timeout?.cancel()
            connection.socket.cancel()
        }
        connections.removeAll()
        pendingCallback = nil
        continuation?.resume(throwing: AuthenticationError.canceled)
    }

    private func stateChanged(_ state: NWListener.State) {
        guard listener != nil else { return }
        switch state {
        case .ready:
            guard let assignedPort = listener?.port?.rawValue, assignedPort != 0 else {
                fail(.browserUnavailable)
                return
            }
            port = assignedPort
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: OAuthProtocol.redirectURI(port: assignedPort))
        case .failed:
            fail(.browserUnavailable)
        default: break
        }
    }

    private func fail(_ error: AuthenticationError) {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(throwing: error)
        onFailure?(error)
        cancel()
    }

    private func accept(_ socket: NWConnection) {
        guard listener != nil, connections.count < 8 else { socket.cancel(); return }
        let id = UUID()
        var connection = Connection(socket: socket)
        connection.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close(id)
        }
        connections[id] = connection
        socket.start(queue: .global(qos: .userInitiated))
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let connection = connections[id] else { return }
        connection.socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable [weak self] data, _, isComplete, error in
            let target = self
            Task { @MainActor in target?.received(data, complete: isComplete, failed: error != nil, id: id) }
        }
    }

    private func received(_ data: Data?, complete: Bool, failed: Bool, id: UUID) {
        guard var connection = connections[id], let port else { close(id); return }
        guard !failed else { close(id); return }
        do {
            let headers = try connection.headers.append(data ?? Data())
            connections[id] = connection
            if let headers {
                let target = try OAuthProtocol.requestTarget(headers: headers, port: port)
                guard target.split(separator: "?", maxSplits: 1).first == Substring(OAuthProtocol.callbackPath) else {
                    send(OAuthProtocol.response(status: "404 Not Found"), id: id)
                    return
                }
                let callback = try OAuthProtocol.callback(from: target, attempt: attempt)
                guard !acceptedCallback else { send(OAuthProtocol.response(status: "409 Conflict"), id: id); return }
                // The native bridge can complete immediately; make the private result available first.
                acceptedCallback = true
                pendingCallback = callback
                send(OAuthProtocol.response(status: "302 Found", location: OAuthProtocol.bridgeURL(attemptID: attempt.bridgeID)), id: id)
            } else if complete {
                close(id)
            } else {
                receive(id)
            }
        } catch {
            if error as? AuthenticationError == .incompleteRegistration {
                fail(.incompleteRegistration)
                return
            }
            send(OAuthProtocol.response(status: "400 Bad Request"), id: id)
        }
    }

    private func send(_ data: Data, id: UUID) {
        guard let connection = connections[id] else { return }
        connection.socket.send(content: data, completion: .contentProcessed({ @Sendable [weak self] _ in
            let target = self
            Task { @MainActor in target?.close(id) }
        }))
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timeout?.cancel()
        connection.socket.cancel()
    }
}
