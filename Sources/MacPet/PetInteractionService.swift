import Foundation
import Network

protocol PetInteractionService: Sendable {
    func availablePeers() async -> [PetPeer]
    func pair(room: String, name: String) async
    func send(_ event: PetEvent, to peerID: String) async
    func incomingEvents() async -> AsyncStream<PetEvent>
}

/// Test-only stand-in that keeps the model tests deterministic.
actor LocalPetInteractionService: PetInteractionService {
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private let responseDelay: Duration
    private var peers: [PetPeer] = []

    init(responseDelay: Duration = .milliseconds(850)) {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation
        self.responseDelay = responseDelay
    }

    func incomingEvents() async -> AsyncStream<PetEvent> {
        stream
    }

    func availablePeers() async -> [PetPeer] {
        peers
    }

    func pair(room: String, name: String) async {}

    func setPeers(_ peers: [PetPeer]) {
        self.peers = peers
    }

    func send(_ event: PetEvent, to peerID: String) async {
        try? await Task.sleep(for: responseDelay)
        let friendName = peers.first(where: { $0.id == peerID })?.name ?? "朋友"
        continuation.yield(PetEvent(kind: event.kind, senderName: friendName, frameName: event.frameName))
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
    private let deviceID: String
    private let deviceName: String
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private let listener: NWListener?
    private let browser: NWBrowser
    private var peers: [String: NWBrowser.Result] = [:]

    init() {
        let defaults = UserDefaults.standard
        let identityKey = "com.macpet.device-id"
        let storedID = defaults.string(forKey: identityKey)
        let generatedID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        deviceID = storedID ?? generatedID
        if storedID == nil { defaults.set(generatedID, forKey: identityKey) }
        deviceName = String((Host.current().localizedName ?? "一位朋友").prefix(6))
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
                name: Self.serviceName(deviceID: deviceID, name: deviceName),
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
            guard let self else { return }
            self.peers = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                guard let peer = Self.peer(from: result.endpoint), peer.id != self.deviceID else { return nil }
                return (peer.id, result)
            })
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

    func availablePeers() async -> [PetPeer] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let peers = self?.peers.values.compactMap { Self.peer(from: $0.endpoint) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                continuation.resume(returning: peers)
            }
        }
    }

    func pair(room: String, name: String) async {}

    func send(_ event: PetEvent, to peerID: String) async {
        let envelope = Envelope(senderID: deviceID, senderName: deviceName, kind: event.kind, frameName: event.frameName)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        queue.async { [weak self] in
            guard let self, let peer = self.peers[peerID] else { return }
            self.send(data, to: peer.endpoint)
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

    private static func serviceName(deviceID: String, name: String) -> String {
        let encoded = Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "mp-\(deviceID)-\(encoded)"
    }

    private static func peer(from endpoint: NWEndpoint) -> PetPeer? {
        guard case let .service(name, _, _, _) = endpoint else { return nil }
        let components = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "mp" else { return nil }
        var encoded = String(components[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded), let displayName = String(data: data, encoding: .utf8), !displayName.isEmpty else { return nil }
        return PetPeer(id: String(components[1]), name: displayName)
    }
}

/// Public, server-mediated transport for friends who are not on the same Wi-Fi.
final class PublicPetInteractionService: @unchecked Sendable, PetInteractionService {
    private let endpoint = URL(string: "wss://happypuppy.io/ws")!
    private let deviceName = Host.current().localizedName ?? "一位朋友"
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private var task: URLSessionWebSocketTask?

    init() {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation
    }

    deinit { task?.cancel(with: .goingAway, reason: nil); continuation.finish() }

    func availablePeers() async -> [PetPeer] { [] }

    func incomingEvents() async -> AsyncStream<PetEvent> { stream }

    func pair(room: String, name: String) async {
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: endpoint)
        self.task = task
        task.resume()
        await sendJSON(["type": "join", "room": room, "name": name], through: task)
        receive(on: task)
    }

    func send(_ event: PetEvent, to peerID: String) async {
        await sendJSON(["type": "event", "kind": event.kind.rawValue, "frameName": event.frameName], through: task)
    }

    private func sendJSON(_ object: [String: String], through task: URLSessionWebSocketTask?) async {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            if case let .success(.string(text)) = result,
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["type"] as? String == "event",
               let kindText = json["kind"] as? String,
               let kind = PetEvent.Kind(rawValue: kindText),
               let frame = json["frameName"] as? String,
               let sender = json["senderName"] as? String {
                self.continuation.yield(PetEvent(kind: kind, senderName: sender, frameName: frame))
            }
            if case .success = result { self.receive(on: task) }
        }
    }
}
