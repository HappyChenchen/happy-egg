import Foundation

@MainActor
final class AppModel {
    enum Emotion: Equatable {
        case idle
        case happy
    }

    private let service: any PetInteractionService
    private static let pairingAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    private var listeningTask: Task<Void, Never>?
    private var peerRefreshTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private(set) var bubbleText: String?
    private(set) var emotion: Emotion = .idle
    private(set) var activeFrameName = BuddyFrames.names[BuddyFrames.initialIndex]
    private(set) var nearbyPeers: [PetPeer] = []
    private(set) var pairedFriend: PetPeer?
    private(set) var friends: [PetPeer] = []
    private(set) var peerID: String
    private(set) var ownerName: String
    private(set) var petName: String
    private(set) var petScale: PetScale
    var onStateChange: (() -> Void)?
    var onPeersChange: (() -> Void)?
    var onScaleChange: (() -> Void)?

    var confirmedFriend: PetPeer? {
        guard let pairedFriend, !Self.isPendingFriendName(pairedFriend.name) else { return nil }
        return pairedFriend
    }

    init(service: any PetInteractionService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        let savedPeerID = defaults.string(forKey: "com.macpet.peer-id")?.lowercased()
        peerID = savedPeerID.flatMap(Self.validProfileID) ?? Self.makeProfileID()
        defaults.set(peerID, forKey: "com.macpet.peer-id")
        petScale = PetScale(rawValue: defaults.object(forKey: "com.macpet.pet-scale") as? CGFloat ?? 1) ?? .normal
        ownerName = defaults.string(forKey: "com.macpet.owner-name") ?? "我"
        petName = defaults.string(forKey: "com.macpet.pet-name") ?? "我的宠物"
        if let data = defaults.data(forKey: "com.macpet.friends"), let saved = try? JSONDecoder().decode([PetPeer].self, from: data) {
            friends = Self.deduplicatedFriends(saved)
            if friends != saved { persistFriends() }
        }
    }

    deinit {
        listeningTask?.cancel()
        peerRefreshTask?.cancel()
        connectionTask?.cancel()
    }

    func startListening() {
        guard listeningTask == nil else { return }
        let service = service
        listeningTask = Task { [weak self] in
            let events = await service.incomingEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
        let connectionService = service
        connectionTask = Task { [weak self] in
            let updates = await connectionService.connectionUpdates()
            for await update in updates {
                guard let self else { return }
                switch update {
                case let .peerAvailable(name, remotePeerID):
                    guard let friend = self.pairedFriend else { continue }
                    self.pairedFriend = PetPeer(id: friend.id, name: name, peerID: remotePeerID ?? friend.peerID)
                    self.saveFriend(self.pairedFriend!)
                    self.onPeersChange?()
                    self.setState(text: "已配对 \(name)", emotion: .happy, frameName: self.activeFrameName)
                case let .peerRenamed(name, remotePeerID):
                    guard let friend = self.pairedFriend else { continue }
                    let oldName = friend.name
                    self.pairedFriend = PetPeer(id: friend.id, name: name, peerID: remotePeerID ?? friend.peerID)
                    self.saveFriend(self.pairedFriend!)
                    self.onPeersChange?()
                    let message = oldName == name || Self.isPendingFriendName(oldName) ? "已配对 \(name)" : "\(oldName) 改名为 \(name)"
                    self.setState(text: message, emotion: .happy, frameName: self.activeFrameName)
                case .peerUnavailable:
                    guard self.pairedFriend != nil else { continue }
                    self.setState(text: "朋友已离线，等待重连", emotion: .idle, frameName: self.activeFrameName)
                case .connectionLost:
                    guard self.pairedFriend != nil else { continue }
                    self.setState(text: "连接已断开，正在重连", emotion: .idle, frameName: self.activeFrameName)
                case let .connectionFailed(message):
                    self.setState(text: message, emotion: .idle, frameName: self.activeFrameName)
                }
            }
        }
    }

    func startRefreshingPeers() {
        guard peerRefreshTask == nil else { return }
        peerRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPeers()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refreshPeers() async {
        nearbyPeers = await service.availablePeers()
        onPeersChange?()
    }

    func pair(with peer: PetPeer) {
        pairedFriend = peer
        onPeersChange?()
        setState(text: "已配对 \(peer.name)", emotion: .happy, frameName: activeFrameName)
    }

    func unpair() {
        pairedFriend = nil
        onPeersChange?()
        Task { await service.stop() }
    }

    func selectFriend(_ friend: PetPeer) async {
        pairedFriend = friend
        await service.pair(room: friend.id, name: petName, peerID: peerID)
        onPeersChange?()
        setState(text: "正在连接 \(friend.name)", emotion: .happy, frameName: activeFrameName)
    }

    func createPublicPairing() async -> String {
        let code = Self.makePairingCode()
        pairedFriend = PetPeer(id: code, name: "配对码已创建")
        await service.pair(room: code, name: petName, peerID: peerID)
        onPeersChange?()
        setState(text: "配对码 \(code) 已复制，发给朋友", emotion: .happy, frameName: activeFrameName)
        return code
    }

    func joinPublicPairing(code: String) async {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidPairingCode(normalized) else {
            setState(text: "配对码格式不正确", emotion: .idle, frameName: activeFrameName)
            return
        }
        pairedFriend = PetPeer(id: normalized, name: "正在加入配对")
        await service.pair(room: normalized, name: petName, peerID: peerID)
        onPeersChange?()
        setState(text: "已加入配对，等待朋友互动", emotion: .happy, frameName: activeFrameName)
    }

    func setPetScale(_ scale: PetScale) {
        petScale = scale
        defaults.set(Double(scale.rawValue), forKey: "com.macpet.pet-scale")
        onScaleChange?()
    }

    func sendInteraction(kind: PetEvent.Kind, frameName: String? = nil) async {
        let selectedFrame = frameName ?? kind.defaultFrameName
        let safeFrame = BuddyFrames.names.contains(selectedFrame) ? selectedFrame : kind.defaultFrameName
        guard let pairedFriend = confirmedFriend else {
            setState(text: "本地互动成功，配对后可拍朋友", emotion: .happy, frameName: safeFrame)
            return
        }
        setState(text: outgoingText(for: kind, friendName: pairedFriend.name), emotion: .happy, frameName: safeFrame)
        await service.send(PetEvent(kind: kind, senderName: "我", frameName: safeFrame), to: pairedFriend.id)
    }

    private func receive(_ event: PetEvent) {
        if let currentFriend = pairedFriend, Self.isPendingFriendName(currentFriend.name) {
            pairedFriend = PetPeer(id: currentFriend.id, name: event.senderName)
            saveFriend(pairedFriend!)
            onPeersChange?()
        }
        let frameName = BuddyFrames.names.contains(event.frameName) ? event.frameName : event.kind.defaultFrameName
        setState(text: "\(event.senderName)\(event.kind.incomingText)", emotion: .happy, frameName: frameName)
    }

    private func setState(text: String, emotion: Emotion, frameName: String) {
        bubbleText = text
        self.emotion = emotion
        activeFrameName = frameName
        onStateChange?()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard let self, self.bubbleText == text else { return }
            self.bubbleText = nil
            self.emotion = .idle
            self.onStateChange?()
        }
    }

    private func outgoingText(for kind: PetEvent.Kind, friendName: String) -> String {
        switch kind {
        case .poke: "已拍一拍 \(friendName)"
        case .heart: "已送爱心给 \(friendName)"
        case .celebrate: "已邀请 \(friendName) 一起庆祝"
        }
    }

    func setProfile(owner: String, pet: String) {
        let oldPetName = petName
        ownerName = Self.cleanName(owner, fallback: "我")
        petName = Self.cleanName(pet, fallback: "我的宠物")
        defaults.set(ownerName, forKey: "com.macpet.owner-name")
        defaults.set(petName, forKey: "com.macpet.pet-name")
        guard oldPetName != petName, confirmedFriend != nil else { return }
        let service = service
        let newName = petName
        Task {
            await service.updateName(newName)
        }
        setState(text: "名字已更新，朋友会看到", emotion: .happy, frameName: activeFrameName)
    }

    private func saveFriend(_ friend: PetPeer) {
        friends.removeAll {
            $0.id == friend.id
                || (friend.peerID != nil && $0.peerID == friend.peerID)
                || (friend.peerID == nil && $0.peerID == nil && $0.name == friend.name)
        }
        friends.append(friend)
        persistFriends()
    }

    private func persistFriends() {
        if let data = try? JSONEncoder().encode(friends) { defaults.set(data, forKey: "com.macpet.friends") }
    }

    private static func deduplicatedFriends(_ friends: [PetPeer]) -> [PetPeer] {
        var result: [PetPeer] = []
        for friend in friends {
            result.removeAll {
                $0.id == friend.id
                    || (friend.peerID != nil && $0.peerID == friend.peerID)
                    || (friend.peerID == nil && $0.peerID == nil && $0.name == friend.name)
            }
            result.append(friend)
        }
        return result
    }

    private static func isPendingFriendName(_ name: String) -> Bool {
        name == "配对码已创建" || name == "正在加入配对"
    }

    private static func makePairingCode() -> String {
        String((0..<8).compactMap { _ in pairingAlphabet.randomElement() })
    }

    private static func makeProfileID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func validProfileID(_ value: String) -> String? {
        value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) == nil ? nil : value
    }

    private static func isValidPairingCode(_ code: String) -> Bool {
        code.range(of: "^[a-hj-km-np-z2-9]{8}$", options: .regularExpression) != nil
            || code.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func cleanName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(20))
    }
}
