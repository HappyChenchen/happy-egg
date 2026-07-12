import Foundation

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
