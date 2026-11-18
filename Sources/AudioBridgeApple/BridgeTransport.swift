import Foundation
import Network

public enum BridgeService {
    /// Dedicated Bonjour service type. Must also be listed in NSBonjourServices of any app that browses/advertises it.
    public static let type = "_audiobridge._udp"

    /// UDP parameters for realtime audio: peer-to-peer Wi-Fi allowed, voice service class.
    /// NOTE (spike): unencrypted. Before shipping, switch to DTLS with a pre-shared key derived from pairing.
    public static func parameters() -> NWParameters {
        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice
        return params
    }
}

/// Advertises `_audiobridge._udp` and delivers each received datagram. One active sender at a time:
/// a new sender replaces the previous one.
public final class BridgeReceiver: @unchecked Sendable {
    public let serviceName: String
    public let requestedPort: UInt16?
    /// Called on `queue` for every datagram.
    public var onDatagram: ((Data) -> Void)?
    public var onEvent: (@Sendable (String) -> Void)?
    public let queue = DispatchQueue(label: "audiobridge.receiver", qos: .userInteractive)

    private var listener: NWListener?
    private var connection: NWConnection?

    public init(serviceName: String, port: UInt16? = nil) {
        self.serviceName = serviceName
        self.requestedPort = port
    }

    public func start() throws {
        let params = BridgeService.parameters()
        let listener: NWListener
        if let requestedPort, let port = NWEndpoint.Port(rawValue: requestedPort) {
            listener = try NWListener(using: params, on: port)
        } else {
            listener = try NWListener(using: params)
        }
        listener.service = NWListener.Service(name: serviceName, type: BridgeService.type)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent?("listening on UDP port \(listener?.port?.rawValue ?? 0) as \"\(self.serviceName)\" (\(BridgeService.type))")
            case .waiting(let error):
                self.onEvent?("listener waiting: \(error) — if this is a local-network permission issue, allow it in System Settings › Privacy & Security › Local Network")
            case .failed(let error):
                self.onEvent?("listener failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    private func adopt(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        onEvent?("sender connected: \(newConnection.endpoint)")
        newConnection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onEvent?("sender connection failed: \(error)") }
        }
        newConnection.start(queue: queue)
        receive(on: newConnection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty { self.onDatagram?(data) }
            if let error {
                self.onEvent?("receive error: \(error)")
                return
            }
            if case .cancelled = connection.state { return }
            self.receive(on: connection)
        }
    }
}

/// Sends datagrams to one receiver endpoint.
public final class BridgeSender: @unchecked Sendable {
    public let endpoint: NWEndpoint
    public var onEvent: (@Sendable (String) -> Void)?
    private let connection: NWConnection
    public let queue = DispatchQueue(label: "audiobridge.sender", qos: .userInteractive)

    public init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        self.connection = NWConnection(to: endpoint, using: BridgeService.parameters())
    }

    public func start(onReady: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onEvent?("connected to \(self?.endpoint.debugDescription ?? "?")")
                onReady()
            case .waiting(let error):
                self?.onEvent?("waiting: \(error)")
            case .failed(let error):
                self?.onEvent?("failed: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    public func cancel() {
        connection.cancel()
    }

    /// Browses for receivers and calls `found` once with the first match (optionally filtered by name).
    public static func browse(
        named name: String?,
        timeout: TimeInterval,
        queue: DispatchQueue = .main,
        found: @escaping @Sendable (NWEndpoint?) -> Void
    ) -> NWBrowser {
        let browser = NWBrowser(for: .bonjour(type: BridgeService.type, domain: nil), using: BridgeService.parameters())
        let done = OneShot()
        browser.browseResultsChangedHandler = { results, _ in
            let match = results.first { result in
                guard let name else { return true }
                if case let .service(serviceName, _, _, _) = result.endpoint { return serviceName == name }
                return false
            }
            if let match, done.fire() {
                browser.cancel()
                found(match.endpoint)
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state, done.fire() { found(nil) }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            if done.fire() {
                browser.cancel()
                found(nil)
            }
        }
        return browser
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
