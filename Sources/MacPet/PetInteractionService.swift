import Foundation
import Network

protocol PetInteractionService: Sendable {
    func send(_ event: PetEvent) async
    func incomingEvents() async -> AsyncStream<PetEvent>
}

/// Test-only stand-in that keeps the model tests deterministic.
actor LocalPetInteractionService: PetInteractionService {
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private let responseDelay: Duration

    init(responseDelay: Duration = .milliseconds(850)) {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation
        self.responseDelay = responseDelay
    }

    func incomingEvents() async -> AsyncStream<PetEvent> {
        stream
    }

    func send(_ event: PetEvent) async {
        try? await Task.sleep(for: responseDelay)
        continuation.yield(PetEvent(kind: event.kind, senderName: "朋友", frameName: event.frameName))
    }

    func simulateIncomingPoke(from name: String) {
        continuation.yield(PetEvent(senderName: name))
    }
}

/// Direct, serverless interaction for Macs on the same local network.
/// Bonjour finds nearby MacPet instances and each poke is delivered to them
/// over a short-lived TCP connection.
final class LocalNetworkPetInteractionService: @unchecked Sendable, PetInteractionService {
    private static let serviceType = "_macpet-poke._tcp"

    private struct Envelope: Codable {
        let senderID: String
        let senderName: String
        let kind: PetEvent.Kind
        let frameName: String
    }

    private let queue = DispatchQueue(label: "com.macpet.lan")
    private let deviceID = UUID().uuidString
    private let deviceName = Host.current().localizedName ?? "一位朋友"
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private let listener: NWListener?
    private let browser: NWBrowser
    private var peers = Set<NWBrowser.Result>()

    init() {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation

        let parameters = NWParameters.tcp
        browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )

        if let listener = try? NWListener(using: parameters) {
            listener.service = NWListener.Service(
                name: "MacPet-\(String(deviceID.prefix(6)))",
                type: Self.serviceType
            )
            self.listener = listener
        } else {
            self.listener = nil
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.peers = results
        }
        listener?.start(queue: queue)
        browser.start(queue: queue)
    }

    deinit {
        listener?.cancel()
        browser.cancel()
        continuation.finish()
    }

    func incomingEvents() async -> AsyncStream<PetEvent> {
        stream
    }

    func send(_ event: PetEvent) async {
        let envelope = Envelope(senderID: deviceID, senderName: deviceName, kind: event.kind, frameName: event.frameName)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for peer in self.peers {
                self.send(data, to: peer.endpoint)
            }
        }
    }

    private func send(_ data: Data, to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.senderID != self.deviceID else { return }
            self.continuation.yield(PetEvent(kind: envelope.kind, senderName: envelope.senderName, frameName: envelope.frameName))
        }
    }
}
