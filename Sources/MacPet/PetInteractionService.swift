import Foundation

enum PetConnectionUpdate: Equatable, Sendable {
    case peerAvailable(name: String, peerID: String?)
    case peerRenamed(name: String, peerID: String?)
    case peerUnavailable
    case connectionLost
    case connectionFailed(message: String)
}

protocol PetInteractionService: Sendable {
    func availablePeers() async -> [PetPeer]
    func pair(room: String, name: String, peerID: String) async
    func stop() async
    func updateName(_ name: String) async
    func send(_ event: PetEvent, to peerID: String) async
    func incomingEvents() async -> AsyncStream<PetEvent>
    func connectionUpdates() async -> AsyncStream<PetConnectionUpdate>
}

/// Test-only stand-in that keeps the model tests deterministic.
actor LocalPetInteractionService: PetInteractionService {
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private let connectionStream: AsyncStream<PetConnectionUpdate>
    private let connectionContinuation: AsyncStream<PetConnectionUpdate>.Continuation
    private let responseDelay: Duration
    private var peers: [PetPeer] = []
    private var updatedNames: [String] = []

    init(responseDelay: Duration = .milliseconds(850)) {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation
        var savedConnection: AsyncStream<PetConnectionUpdate>.Continuation!
        connectionStream = AsyncStream { savedConnection = $0 }
        connectionContinuation = savedConnection
        self.responseDelay = responseDelay
    }

    func incomingEvents() async -> AsyncStream<PetEvent> {
        stream
    }
    func connectionUpdates() async -> AsyncStream<PetConnectionUpdate> { connectionStream }

    func availablePeers() async -> [PetPeer] {
        peers
    }

    func pair(room: String, name: String, peerID: String) async {}
    func stop() async {}
    func updateName(_ name: String) async { updatedNames.append(name) }

    func updatedNameValues() -> [String] { updatedNames }

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

    func simulatePeerRenamed(to name: String) {
        connectionContinuation.yield(.peerRenamed(name: name, peerID: nil))
    }

    func simulatePeerAvailable(name: String) {
        connectionContinuation.yield(.peerAvailable(name: name, peerID: nil))
    }

    func simulatePeerUnavailable() {
        connectionContinuation.yield(.peerUnavailable)
    }
}

/// Public, server-mediated transport for friends who are not on the same Wi-Fi.
final class PublicPetInteractionService: @unchecked Sendable, PetInteractionService {
    private let endpoint = URL(string: "wss://happypuppy.io/ws")!
    private let stream: AsyncStream<PetEvent>
    private let continuation: AsyncStream<PetEvent>.Continuation
    private let connectionStream: AsyncStream<PetConnectionUpdate>
    private let connectionContinuation: AsyncStream<PetConnectionUpdate>.Continuation
    private var task: URLSessionWebSocketTask?
    private var pairingRoom: String?
    private var pairingName: String?
    private var pairingPeerID: String?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectEnabled = false

    init() {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation
        var savedConnection: AsyncStream<PetConnectionUpdate>.Continuation!
        connectionStream = AsyncStream { savedConnection = $0 }
        connectionContinuation = savedConnection
    }

    deinit {
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
        connectionContinuation.finish()
    }

    func availablePeers() async -> [PetPeer] { [] }

    func incomingEvents() async -> AsyncStream<PetEvent> { stream }
    func connectionUpdates() async -> AsyncStream<PetConnectionUpdate> { connectionStream }

    func pair(room: String, name: String, peerID: String) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        pairingRoom = room
        pairingName = name
        pairingPeerID = peerID
        reconnectEnabled = true
        task?.cancel(with: .goingAway, reason: nil)
        await connect(room: room, name: name, peerID: peerID)
    }

    func stop() async {
        reconnectEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pairingRoom = nil
        pairingName = nil
        pairingPeerID = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ event: PetEvent, to peerID: String) async {
        await sendJSON(["type": "event", "kind": event.kind.rawValue, "frameName": event.frameName], through: task)
    }

    func updateName(_ name: String) async {
        pairingName = name
        var payload = ["type": "profile", "name": name]
        if let pairingPeerID { payload["peerID"] = pairingPeerID }
        await sendJSON(payload, through: task)
    }

    private func connect(room: String, name: String, peerID: String) async {
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        task = socket
        socket.resume()
        let payload = ["type": "join", "room": room, "name": name, "peerID": peerID]
        await sendJSON(payload, through: socket)
        receive(on: socket)
    }

    private func sendJSON(_ object: [String: String], through task: URLSessionWebSocketTask?) async {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard self.task === task else { return }
            switch result {
            case let .success(.string(text)):
                self.handleMessage(text)
                self.receive(on: task)
            case .success, .failure:
                self.handleConnectionLoss(for: task)
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if json["type"] as? String == "error" {
            reconnectEnabled = false
            connectionContinuation.yield(.connectionFailed(message: "配对失败，请检查配对码"))
            return
        }
        if json["type"] as? String == "event",
           let kindText = json["kind"] as? String,
           let kind = PetEvent.Kind(rawValue: kindText),
           let frame = json["frameName"] as? String,
           let sender = json["senderName"] as? String {
            continuation.yield(PetEvent(kind: kind, senderName: sender, frameName: frame))
        } else if json["type"] as? String == "profile", let name = json["peerName"] as? String {
            connectionContinuation.yield(.peerRenamed(name: name, peerID: json["peerID"] as? String))
        } else if json["type"] as? String == "presence" {
            if let connected = json["connected"] as? Int, connected < 2 {
                connectionContinuation.yield(.peerUnavailable)
            } else if let name = json["peerName"] as? String {
                connectionContinuation.yield(.peerAvailable(name: name, peerID: json["peerID"] as? String))
            }
        } else if let name = json["peerName"] as? String {
            connectionContinuation.yield(.peerAvailable(name: name, peerID: json["peerID"] as? String))
        }
    }

    private func handleConnectionLoss(for task: URLSessionWebSocketTask) {
        guard self.task === task, reconnectEnabled, pairingRoom != nil else { return }
        connectionContinuation.yield(.connectionLost)
        guard reconnectTask == nil, let room = pairingRoom, let name = pairingName, let peerID = pairingPeerID else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.reconnectEnabled else { return }
            self.reconnectTask = nil
            await self.connect(room: room, name: name, peerID: peerID)
        }
    }
}
