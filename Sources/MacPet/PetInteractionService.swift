import Foundation

enum PetConnectionUpdate: Equatable, Sendable {
    case peerAvailable(name: String, peerID: String?)
    case peerRenamed(name: String, peerID: String?)
    case peerUnavailable
    case connectionLost
    case connectionFailed(message: String)
    case presenceSnapshot(onlinePeerIDs: Set<String>)
    case friendPresence(peerID: String, isOnline: Bool)
    case friendProfile(peerID: String, name: String)
    case petCode(String)
    case friendRequest(PetFriendRequest)
    case friendRequestAccepted(requestID: String, peer: PetPeer)
    case friendRequestRejected(requestID: String)
    case friendRequestFailed(message: String)
}

protocol PetInteractionService: Sendable {
    func pair(room: String, name: String, peerID: String) async
    func stop() async
    func updateName(_ name: String) async
    func updatePresence(peerID: String, authToken: String, name: String, friendPeerIDs: Set<String>) async
    func requestFriend(code: String) async -> Bool
    func respondToFriendRequest(id: String, accept: Bool) async -> Bool
    func resetPetCode() async -> Bool
    func acknowledgeFriendRequest(id: String) async
    func send(_ event: PetEvent, to peerID: String) async -> Bool
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
    private let sendSucceeds: Bool
    private var updatedNames: [String] = []
    private var presenceSubscriptions: [Set<String>] = []
    private var sentTargets: [String] = []
    private var pairedRooms: [String] = []
    private var requestedFriendCodes: [String] = []
    private var friendRequestResponses: [(String, Bool)] = []

    init(responseDelay: Duration = .milliseconds(850), sendSucceeds: Bool = true) {
        var savedContinuation: AsyncStream<PetEvent>.Continuation!
        stream = AsyncStream { savedContinuation = $0 }
        continuation = savedContinuation
        var savedConnection: AsyncStream<PetConnectionUpdate>.Continuation!
        connectionStream = AsyncStream { savedConnection = $0 }
        connectionContinuation = savedConnection
        self.responseDelay = responseDelay
        self.sendSucceeds = sendSucceeds
    }

    func incomingEvents() async -> AsyncStream<PetEvent> {
        stream
    }
    func connectionUpdates() async -> AsyncStream<PetConnectionUpdate> { connectionStream }

    func pair(room: String, name: String, peerID: String) async { pairedRooms.append(room) }
    func stop() async {}
    func updateName(_ name: String) async { updatedNames.append(name) }
    func updatePresence(peerID: String, authToken: String, name: String, friendPeerIDs: Set<String>) async {
        presenceSubscriptions.append(friendPeerIDs)
    }
    func requestFriend(code: String) async -> Bool { requestedFriendCodes.append(code); return sendSucceeds }
    func respondToFriendRequest(id: String, accept: Bool) async -> Bool {
        friendRequestResponses.append((id, accept)); return sendSucceeds
    }
    func resetPetCode() async -> Bool { sendSucceeds }
    func acknowledgeFriendRequest(id: String) async {}

    func updatedNameValues() -> [String] { updatedNames }
    func presenceSubscriptionValues() -> [Set<String>] { presenceSubscriptions }
    func sentTargetValues() -> [String] { sentTargets }
    func pairedRoomValues() -> [String] { pairedRooms }
    func requestedFriendCodeValues() -> [String] { requestedFriendCodes }
    func friendRequestResponseValues() -> [(String, Bool)] { friendRequestResponses }

    func send(_ event: PetEvent, to peerID: String) async -> Bool {
        sentTargets.append(peerID)
        guard sendSucceeds else { return false }
        try? await Task.sleep(for: responseDelay)
        continuation.yield(PetEvent(kind: event.kind, senderName: "朋友", frameName: event.frameName))
        return true
    }

    func simulateIncomingPoke(from name: String) {
        continuation.yield(PetEvent(senderName: name))
    }

    func simulatePeerRenamed(to name: String, peerID: String? = nil) {
        connectionContinuation.yield(.peerRenamed(name: name, peerID: peerID))
    }

    func simulatePeerAvailable(name: String, peerID: String? = nil) {
        connectionContinuation.yield(.peerAvailable(name: name, peerID: peerID))
    }

    func simulatePeerUnavailable() {
        connectionContinuation.yield(.peerUnavailable)
    }

    func simulatePresenceSnapshot(onlinePeerIDs: Set<String>) {
        connectionContinuation.yield(.presenceSnapshot(onlinePeerIDs: onlinePeerIDs))
    }

    func simulateFriendPresence(peerID: String, isOnline: Bool) {
        connectionContinuation.yield(.friendPresence(peerID: peerID, isOnline: isOnline))
    }
    func simulateFriendProfile(peerID: String, name: String) {
        connectionContinuation.yield(.friendProfile(peerID: peerID, name: name))
    }
    func simulatePetCode(_ code: String) { connectionContinuation.yield(.petCode(code)) }
    func simulateFriendRequest(_ request: PetFriendRequest) { connectionContinuation.yield(.friendRequest(request)) }
    func simulateFriendRequestAccepted(requestID: String, peer: PetPeer) {
        connectionContinuation.yield(.friendRequestAccepted(requestID: requestID, peer: peer))
    }
    func simulateFriendRequestRejected(requestID: String) {
        connectionContinuation.yield(.friendRequestRejected(requestID: requestID))
    }
}

/// Public, server-mediated transport for friends who are not on the same Wi-Fi.
@MainActor
final class PublicPetInteractionService: PetInteractionService {
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
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectEnabled = false
    private var presenceTask: URLSessionWebSocketTask?
    private var presencePeerID: String?
    private var presenceAuthToken: String?
    private var presenceName: String?
    private var presenceFriendPeerIDs: Set<String> = []
    private var presenceReconnectTask: Task<Void, Never>?
    private var presenceHeartbeatTask: Task<Void, Never>?
    private var presenceOfflineTask: Task<Void, Never>?
    private var presenceReconnectEnabled = false
    private var pendingDeliveries: [String: CheckedContinuation<Bool, Never>] = [:]
    private var deliveryTimeoutTasks: [String: Task<Void, Never>] = [:]

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
        heartbeatTask?.cancel()
        presenceReconnectTask?.cancel()
        presenceHeartbeatTask?.cancel()
        presenceOfflineTask?.cancel()
        deliveryTimeoutTasks.values.forEach { $0.cancel() }
        pendingDeliveries.values.forEach { $0.resume(returning: false) }
        task?.cancel(with: .goingAway, reason: nil)
        presenceTask?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
        connectionContinuation.finish()
    }

    func incomingEvents() async -> AsyncStream<PetEvent> { stream }
    func connectionUpdates() async -> AsyncStream<PetConnectionUpdate> { connectionStream }

    func pair(room: String, name: String, peerID: String) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pairingRoom = nil
        pairingName = nil
        pairingPeerID = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ event: PetEvent, to peerID: String) async -> Bool {
        if peerID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil {
            guard let socket = presenceTask else { return false }
            let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return await withCheckedContinuation { delivery in
                pendingDeliveries[eventID] = delivery
                deliveryTimeoutTasks[eventID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, let self else { return }
                    self.resolveDelivery(eventID: eventID, delivered: false)
                    self.handlePresenceConnectionLoss(for: socket)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let sent = await self.sendJSON([
                        "type": "friend-event",
                        "eventID": eventID,
                        "targetPeerID": peerID.lowercased(),
                        "kind": event.kind.rawValue,
                        "frameName": event.frameName
                    ], through: socket)
                    if !sent {
                        self.resolveDelivery(eventID: eventID, delivered: false)
                        self.handlePresenceConnectionLoss(for: socket)
                    }
                }
            }
        }
        guard let socket = task else { return false }
        let sent = await sendJSON(["type": "event", "kind": event.kind.rawValue, "frameName": event.frameName], through: socket)
        if !sent { handleConnectionLoss(for: socket) }
        return sent
    }

    func requestFriend(code: String) async -> Bool {
        guard let socket = presenceTask else { return false }
        return await sendJSON(["type": "friend-request-create", "petCode": code], through: socket)
    }

    func respondToFriendRequest(id: String, accept: Bool) async -> Bool {
        guard let socket = presenceTask else { return false }
        return await sendJSON([
            "type": "friend-request-respond", "requestID": id, "accept": accept
        ], through: socket)
    }

    func resetPetCode() async -> Bool {
        guard let socket = presenceTask else { return false }
        return await sendJSON(["type": "pet-code-reset"], through: socket)
    }

    func acknowledgeFriendRequest(id: String) async {
        guard let socket = presenceTask else { return }
        _ = await sendJSON(["type": "friend-request-ack", "requestID": id], through: socket)
    }

    func updateName(_ name: String) async {
        pairingName = name
        var payload = ["type": "profile", "name": name]
        if let pairingPeerID { payload["peerID"] = pairingPeerID }
        if let socket = task, !(await sendJSON(payload, through: socket)) {
            handleConnectionLoss(for: socket)
        }
        presenceName = name
        _ = await sendPresenceRegistration()
    }

    func updatePresence(peerID: String, authToken: String, name: String, friendPeerIDs: Set<String>) async {
        presencePeerID = peerID
        presenceAuthToken = authToken
        presenceName = name
        presenceFriendPeerIDs = friendPeerIDs
        presenceReconnectEnabled = true
        if presenceTask == nil {
            presenceReconnectTask?.cancel()
            presenceReconnectTask = nil
            await connectPresence()
        } else {
            _ = await sendPresenceRegistration()
        }
    }

    private func connect(room: String, name: String, peerID: String) async {
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        task = socket
        socket.resume()
        receive(on: socket)
        startHeartbeat(for: socket, isPresence: false)
        let payload = ["type": "join", "room": room, "name": name, "peerID": peerID]
        if !(await sendJSON(payload, through: socket)) { handleConnectionLoss(for: socket) }
    }

    private func connectPresence() async {
        guard presenceReconnectEnabled, presencePeerID != nil, presenceName != nil else { return }
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        presenceTask = socket
        socket.resume()
        receivePresence(on: socket)
        startHeartbeat(for: socket, isPresence: true)
        if !(await sendPresenceRegistration()) { handlePresenceConnectionLoss(for: socket) }
    }

    private func sendPresenceRegistration() async -> Bool {
        guard let presencePeerID, let presenceAuthToken, let presenceName, let socket = presenceTask else { return false }
        let payload: [String: Any] = [
            "type": "presence-register",
            "peerID": presencePeerID,
            "authToken": presenceAuthToken,
            "name": presenceName,
            "friendPeerIDs": presenceFriendPeerIDs.sorted()
        ]
        let sent = await sendJSON(payload, through: socket)
        if !sent { handlePresenceConnectionLoss(for: socket) }
        return sent
    }

    private func sendJSON(_ object: [String: Any], through task: URLSessionWebSocketTask) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return false }
        do {
            try await task.send(.string(text))
            return true
        } catch {
            return false
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case let .success(.string(text)):
                    self.handleMessage(text)
                    self.receive(on: task)
                case .success, .failure:
                    self.handleConnectionLoss(for: task)
                }
            }
        }
    }

    private func receivePresence(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.presenceTask === task else { return }
                switch result {
                case let .success(.string(text)):
                    self.handlePresenceMessage(text)
                    self.receivePresence(on: task)
                case .success, .failure:
                    self.handlePresenceConnectionLoss(for: task)
                }
            }
        }
    }

    private func startHeartbeat(for socket: URLSessionWebSocketTask, isPresence: Bool) {
        let heartbeat = Task { @MainActor [weak self, weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let socket else { return }
                let isCurrent = isPresence ? self.presenceTask === socket : self.task === socket
                guard isCurrent else { return }
                guard await self.ping(socket) else {
                    if isPresence {
                        self.handlePresenceConnectionLoss(for: socket)
                    } else {
                        self.handleConnectionLoss(for: socket)
                    }
                    return
                }
            }
        }
        if isPresence {
            presenceHeartbeatTask?.cancel()
            presenceHeartbeatTask = heartbeat
        } else {
            heartbeatTask?.cancel()
            heartbeatTask = heartbeat
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask) async -> Bool {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        socket.sendPing { error in
            continuation.yield(error == nil)
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            continuation.yield(false)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? false
        timeout.cancel()
        return result
    }

    private func resolveDelivery(eventID: String, delivered: Bool) {
        deliveryTimeoutTasks.removeValue(forKey: eventID)?.cancel()
        pendingDeliveries.removeValue(forKey: eventID)?.resume(returning: delivered)
    }

    private func failPendingDeliveries() {
        let eventIDs = Array(pendingDeliveries.keys)
        for eventID in eventIDs { resolveDelivery(eventID: eventID, delivered: false) }
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

    private func handlePresenceMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        if type == "presence-snapshot", let peerIDs = json["onlinePeerIDs"] as? [String] {
            presenceOfflineTask?.cancel()
            presenceOfflineTask = nil
            connectionContinuation.yield(.presenceSnapshot(onlinePeerIDs: Set(peerIDs.map { $0.lowercased() })))
        } else if type == "friend-presence",
                  let peerID = json["peerID"] as? String,
                  let isOnline = json["online"] as? Bool {
            connectionContinuation.yield(.friendPresence(peerID: peerID.lowercased(), isOnline: isOnline))
        } else if type == "friend-profile",
                  let peerID = json["peerID"] as? String,
                  let name = json["name"] as? String {
            connectionContinuation.yield(.friendProfile(peerID: peerID.lowercased(), name: name))
        } else if type == "friend-event",
                  let kindText = json["kind"] as? String,
                  let kind = PetEvent.Kind(rawValue: kindText),
                  let frame = json["frameName"] as? String,
                  let sender = json["senderName"] as? String {
            continuation.yield(PetEvent(kind: kind, senderName: sender, frameName: frame))
        } else if type == "friend-event-delivered",
                  let eventID = json["eventID"] as? String {
            resolveDelivery(eventID: eventID.lowercased(), delivered: true)
        } else if type == "friend-event-rejected",
                  let peerID = json["targetPeerID"] as? String {
            if let eventID = json["eventID"] as? String {
                resolveDelivery(eventID: eventID.lowercased(), delivered: false)
            }
            connectionContinuation.yield(.friendPresence(peerID: peerID.lowercased(), isOnline: false))
        } else if type == "pet-code", let code = json["petCode"] as? String {
            connectionContinuation.yield(.petCode(code))
        } else if type == "friend-request-incoming",
                  let requestID = json["requestID"] as? String,
                  let senderPeerID = json["senderPeerID"] as? String,
                  let senderName = json["senderName"] as? String {
            connectionContinuation.yield(.friendRequest(PetFriendRequest(
                id: requestID, senderPeerID: senderPeerID.lowercased(), senderName: senderName
            )))
        } else if type == "friend-request-accepted",
                  let requestID = json["requestID"] as? String,
                  let peerID = json["peerID"] as? String,
                  let name = json["name"] as? String {
            connectionContinuation.yield(.friendRequestAccepted(
                requestID: requestID,
                peer: PetPeer(id: requestID, name: name, peerID: peerID.lowercased())
            ))
        } else if type == "friend-request-rejected", let requestID = json["requestID"] as? String {
            connectionContinuation.yield(.friendRequestRejected(requestID: requestID))
        } else if type == "friend-request-failed", let message = json["message"] as? String {
            connectionContinuation.yield(.friendRequestFailed(message: message))
        }
    }

    private func handleConnectionLoss(for task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        self.task = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task.cancel(with: .goingAway, reason: nil)
        guard reconnectEnabled, pairingRoom != nil else { return }
        connectionContinuation.yield(.connectionLost)
        guard reconnectTask == nil, let room = pairingRoom, let name = pairingName, let peerID = pairingPeerID else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.reconnectEnabled else { return }
            self.reconnectTask = nil
            await self.connect(room: room, name: name, peerID: peerID)
        }
    }

    private func handlePresenceConnectionLoss(for task: URLSessionWebSocketTask) {
        guard presenceTask === task else { return }
        presenceTask = nil
        presenceHeartbeatTask?.cancel()
        presenceHeartbeatTask = nil
        task.cancel(with: .goingAway, reason: nil)
        failPendingDeliveries()
        presenceOfflineTask?.cancel()
        presenceOfflineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.presenceOfflineTask = nil
            self.connectionContinuation.yield(.presenceSnapshot(onlinePeerIDs: []))
        }
        guard presenceReconnectEnabled, presenceReconnectTask == nil else { return }
        presenceReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.presenceReconnectEnabled else { return }
            self.presenceReconnectTask = nil
            await self.connectPresence()
        }
    }
}
