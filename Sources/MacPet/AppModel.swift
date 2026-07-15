import Foundation

@MainActor
final class AppModel {
    enum Emotion: Equatable {
        case idle
        case happy
    }

    private let service: any PetInteractionService
    private static let pairingDigits = Array("0123456789")
    private static let baseDefaultPetName = "陈团团"
    private static let legacyDefaultPetName = "我的宠物"
    private static let applicationIdentifier = "io.happypuppy.macpet"
    private static let legacyApplicationIdentifier = "com.macpet.prototype"
    private static let legacyMigrationKey = "io.happypuppy.macpet.did-migrate-prototype-defaults"
    private static let selectedFriendKey = "com.macpet.selected-friend-id"
    private static let persistedKeys = [
        "com.macpet.peer-id",
        "com.macpet.pet-scale",
        "com.macpet.pet-name",
        "com.macpet.friends",
        selectedFriendKey
    ]
    private var listeningTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let fallbackPetName: String

    private(set) var bubbleText: String?
    private(set) var emotion: Emotion = .idle
    private(set) var activeFrameName = BuddyFrames.names[BuddyFrames.initialIndex]
    private(set) var pairedFriend: PetPeer?
    private(set) var friends: [PetPeer] = []
    private(set) var onlineFriendPeerIDs: Set<String> = []
    private(set) var peerID: String
    private(set) var petName: String
    private(set) var petScale: PetScale
    var onStateChange: (() -> Void)?
    var onSocialStateChange: (() -> Void)?
    var onScaleChange: (() -> Void)?

    static func launchInstanceID(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "--instance"),
              arguments.indices.contains(index + 1) else { return nil }
        let rawID = arguments[index + 1]
        guard rawID.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil else { return nil }
        return rawID.lowercased()
    }

    static func launchDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        let instanceID = launchInstanceID(arguments: arguments)
        let defaults: UserDefaults
        let legacyDomain: String
        if let instanceID {
            defaults = UserDefaults(suiteName: "\(applicationIdentifier).instance.\(instanceID)") ?? .standard
            legacyDomain = "\(legacyApplicationIdentifier).instance.\(instanceID)"
        } else {
            defaults = .standard
            legacyDomain = legacyApplicationIdentifier
        }
        migrateLegacyDefaults(from: legacyDomain, to: defaults)
        return defaults
    }

    var confirmedFriend: PetPeer? {
        guard let pairedFriend, !Self.isPendingFriendName(pairedFriend.name) else { return nil }
        return pairedFriend
    }

    var activePairingCode: String? {
        guard let pairedFriend, pairedFriend.name == "配对码已创建" else { return nil }
        return pairedFriend.id
    }

    init(service: any PetInteractionService, defaults: UserDefaults = .standard, instanceID: String? = nil) {
        self.service = service
        self.defaults = defaults
        fallbackPetName = Self.defaultPetName(for: instanceID)
        let savedPeerID = defaults.string(forKey: "com.macpet.peer-id")?.lowercased()
        peerID = savedPeerID.flatMap(Self.validProfileID) ?? Self.makeProfileID()
        defaults.set(peerID, forKey: "com.macpet.peer-id")
        petScale = PetScale(rawValue: defaults.object(forKey: "com.macpet.pet-scale") as? CGFloat ?? 1) ?? .normal
        let savedPetName = defaults.string(forKey: "com.macpet.pet-name")
        petName = savedPetName == Self.legacyDefaultPetName ? fallbackPetName : (savedPetName ?? fallbackPetName)
        if savedPetName == Self.legacyDefaultPetName { defaults.set(fallbackPetName, forKey: "com.macpet.pet-name") }
        if let data = defaults.data(forKey: "com.macpet.friends"), let saved = try? JSONDecoder().decode([PetPeer].self, from: data) {
            friends = Self.deduplicatedFriends(saved).filter { !Self.isSelfFriend($0, peerID: peerID, petName: petName) }
            if friends != saved { persistFriends() }
        }
        if let selectedID = defaults.string(forKey: Self.selectedFriendKey) {
            pairedFriend = friends.first { Self.selectionID(for: $0) == selectedID }
            if pairedFriend == nil { defaults.removeObject(forKey: Self.selectedFriendKey) }
        }
        if pairedFriend == nil, friends.count == 1, let onlyFriend = friends.first {
            pairedFriend = onlyFriend
            defaults.set(Self.selectionID(for: onlyFriend), forKey: Self.selectedFriendKey)
        }
    }

    deinit {
        listeningTask?.cancel()
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
                    if self.isSelfPeer(name: name, remotePeerID: remotePeerID) {
                        self.rejectSelfPairing()
                        continue
                    }
                    self.pairedFriend = PetPeer(id: friend.id, name: name, peerID: remotePeerID ?? friend.peerID)
                    self.saveFriend(self.pairedFriend!)
                    _ = self.updateFriendPresence(peerID: self.pairedFriend?.peerID, isOnline: true)
                    self.onSocialStateChange?()
                    self.setState(text: "已配对 \(name)", emotion: .happy, frameName: self.activeFrameName)
                case let .peerRenamed(name, remotePeerID):
                    guard let friend = self.pairedFriend else { continue }
                    if self.isSelfPeer(name: name, remotePeerID: remotePeerID) {
                        self.rejectSelfPairing()
                        continue
                    }
                    let oldName = friend.name
                    self.pairedFriend = PetPeer(id: friend.id, name: name, peerID: remotePeerID ?? friend.peerID)
                    self.saveFriend(self.pairedFriend!)
                    _ = self.updateFriendPresence(peerID: self.pairedFriend?.peerID, isOnline: true)
                    self.onSocialStateChange?()
                    let message = oldName == name || Self.isPendingFriendName(oldName) ? "已配对 \(name)" : "\(oldName) 改名为 \(name)"
                    self.setState(text: message, emotion: .happy, frameName: self.activeFrameName)
                case .peerUnavailable:
                    guard self.pairedFriend != nil else { continue }
                    if self.updateFriendPresence(peerID: self.pairedFriend?.peerID, isOnline: false) { self.onSocialStateChange?() }
                    self.setState(text: "朋友已离线，等待重连", emotion: .idle, frameName: self.activeFrameName)
                case .connectionLost:
                    guard self.pairedFriend != nil else { continue }
                    if self.updateFriendPresence(peerID: self.pairedFriend?.peerID, isOnline: false) { self.onSocialStateChange?() }
                    self.setState(text: "连接已断开，正在重连", emotion: .idle, frameName: self.activeFrameName)
                case let .connectionFailed(message):
                    self.setState(text: message, emotion: .idle, frameName: self.activeFrameName)
                case let .presenceSnapshot(onlinePeerIDs):
                    let knownPeerIDs = Set(self.friends.compactMap { $0.peerID?.lowercased() })
                    let nextOnlinePeerIDs = onlinePeerIDs.intersection(knownPeerIDs)
                    guard nextOnlinePeerIDs != self.onlineFriendPeerIDs else { continue }
                    self.onlineFriendPeerIDs = nextOnlinePeerIDs
                    self.onSocialStateChange?()
                case let .friendPresence(remotePeerID, isOnline):
                    let normalizedPeerID = remotePeerID.lowercased()
                    let knownPeerIDs = Set(self.friends.compactMap { $0.peerID?.lowercased() })
                    guard knownPeerIDs.contains(normalizedPeerID) else { continue }
                    if self.updateFriendPresence(peerID: normalizedPeerID, isOnline: isOnline) { self.onSocialStateChange?() }
                }
            }
        }
        refreshPresenceSubscription()
    }

    func removeFriend(_ friend: PetPeer) {
        let previousCount = friends.count
        friends.removeAll { Self.matchesFriend($0, friend) }
        guard friends.count != previousCount else { return }
        if let friendPeerID = friend.peerID?.lowercased() {
            onlineFriendPeerIDs.remove(friendPeerID)
        }
        let removedCurrentFriend = pairedFriend.map { Self.matchesFriend($0, friend) } ?? false
        if removedCurrentFriend {
            pairedFriend = nil
            defaults.removeObject(forKey: Self.selectedFriendKey)
        }
        persistFriends()
        refreshPresenceSubscription()
        onSocialStateChange?()
        setState(text: "已删除好友 \(friend.name)", emotion: .idle, frameName: activeFrameName)
        if removedCurrentFriend { Task { await service.stop() } }
    }

    func selectFriend(_ friend: PetPeer) async {
        pairedFriend = friend
        defaults.set(Self.selectionID(for: friend), forKey: Self.selectedFriendKey)
        if friend.peerID == nil {
            await service.pair(room: friend.id, name: petName, peerID: peerID)
        } else {
            await service.stop()
        }
        onSocialStateChange?()
        let isOnline = isFriendOnline(friend)
        let message = isOnline ? "已选择 \(friend.name)" : "\(friend.name) 当前不在线"
        setState(text: message, emotion: isOnline ? .happy : .idle, frameName: activeFrameName)
    }

    func isFriendOnline(_ friend: PetPeer) -> Bool {
        guard let friendPeerID = friend.peerID?.lowercased() else { return false }
        return onlineFriendPeerIDs.contains(friendPeerID)
    }

    func createPublicPairing() async -> String {
        let code = Self.makePairingCode()
        pairedFriend = PetPeer(id: code, name: "配对码已创建")
        await service.pair(room: code, name: petName, peerID: peerID)
        onSocialStateChange?()
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
        onSocialStateChange?()
        setState(text: "已加入配对，等待朋友互动", emotion: .happy, frameName: activeFrameName)
    }

    func setPetScale(_ scale: PetScale) {
        petScale = scale
        defaults.set(Double(scale.rawValue), forKey: "com.macpet.pet-scale")
        onScaleChange?()
    }

    func interactLocally(frameName: String) {
        let safeFrame = BuddyFrames.names.contains(frameName) ? frameName : PetEvent.Kind.poke.defaultFrameName
        setState(text: "\(petName)开心地回应你", emotion: .happy, frameName: safeFrame)
    }

    func sendInteraction(kind: PetEvent.Kind, frameName: String? = nil) async {
        let selectedFrame = frameName ?? kind.defaultFrameName
        let safeFrame = BuddyFrames.names.contains(selectedFrame) ? selectedFrame : kind.defaultFrameName
        guard let pairedFriend = confirmedFriend else {
            setState(text: "本地互动成功，配对后可拍朋友", emotion: .happy, frameName: safeFrame)
            return
        }
        guard isFriendOnline(pairedFriend) else {
            setState(text: "\(pairedFriend.name) 不在线，未发送", emotion: .idle, frameName: activeFrameName)
            return
        }
        let delivered = await service.send(
            PetEvent(kind: kind, senderName: "我", frameName: safeFrame),
            to: pairedFriend.peerID ?? pairedFriend.id
        )
        guard delivered else {
            if updateFriendPresence(peerID: pairedFriend.peerID, isOnline: false) { onSocialStateChange?() }
            setState(text: "发送失败，正在重新连接", emotion: .idle, frameName: activeFrameName)
            return
        }
        setState(text: outgoingText(for: kind, friendName: pairedFriend.name), emotion: .happy, frameName: safeFrame)
    }

    private func receive(_ event: PetEvent) {
        if let currentFriend = pairedFriend, Self.isPendingFriendName(currentFriend.name) {
            pairedFriend = PetPeer(id: currentFriend.id, name: event.senderName)
            saveFriend(pairedFriend!)
            onSocialStateChange?()
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

    func setPetName(_ name: String) {
        let oldPetName = petName
        petName = Self.cleanName(name, fallback: fallbackPetName)
        defaults.set(petName, forKey: "com.macpet.pet-name")
        guard oldPetName != petName else { return }
        refreshPresenceSubscription()
        guard confirmedFriend != nil else { return }
        let service = service
        let newName = petName
        Task {
            await service.updateName(newName)
        }
        setState(text: "名字已更新，朋友会看到", emotion: .happy, frameName: activeFrameName)
    }

    private func saveFriend(_ friend: PetPeer) {
        guard !isSelfFriend(friend) else { return }
        friends.removeAll {
            $0.id == friend.id
                || (friend.peerID != nil && $0.peerID == friend.peerID)
                || (friend.peerID == nil && $0.peerID == nil && $0.name == friend.name)
        }
        friends.append(friend)
        persistFriends()
        if pairedFriend.map({ Self.matchesFriend($0, friend) }) == true {
            defaults.set(Self.selectionID(for: friend), forKey: Self.selectedFriendKey)
        }
        refreshPresenceSubscription()
    }

    private func persistFriends() {
        if let data = try? JSONEncoder().encode(friends) { defaults.set(data, forKey: "com.macpet.friends") }
    }

    private func refreshPresenceSubscription() {
        let friendPeerIDs = Set(friends.compactMap { $0.peerID?.lowercased() })
        onlineFriendPeerIDs.formIntersection(friendPeerIDs)
        let service = service
        let localPeerID = peerID
        let localPetName = petName
        Task {
            await service.updatePresence(peerID: localPeerID, name: localPetName, friendPeerIDs: friendPeerIDs)
        }
    }

    private func updateFriendPresence(peerID: String?, isOnline: Bool) -> Bool {
        guard let peerID = peerID?.lowercased() else { return false }
        if isOnline {
            return onlineFriendPeerIDs.insert(peerID).inserted
        }
        return onlineFriendPeerIDs.remove(peerID) != nil
    }

    private func isSelfFriend(_ friend: PetPeer) -> Bool {
        Self.isSelfFriend(friend, peerID: peerID, petName: petName)
    }

    private static func isSelfFriend(_ friend: PetPeer, peerID: String, petName: String) -> Bool {
        friend.peerID == peerID
            || (friend.peerID == nil && (friend.name == petName || friend.name == legacyDefaultPetName))
    }

    private func isSelfPeer(name: String, remotePeerID: String?) -> Bool {
        remotePeerID == peerID || (remotePeerID == nil && (name == petName || name == Self.legacyDefaultPetName))
    }

    private func rejectSelfPairing() {
        pairedFriend = nil
        onSocialStateChange?()
        setState(text: "不能和自己的宠物配对", emotion: .idle, frameName: activeFrameName)
        Task { await service.stop() }
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

    private static func matchesFriend(_ lhs: PetPeer, _ rhs: PetPeer) -> Bool {
        lhs.id == rhs.id || (lhs.peerID != nil && lhs.peerID == rhs.peerID)
    }

    private static func selectionID(for friend: PetPeer) -> String {
        friend.peerID?.lowercased() ?? friend.id
    }

    private static func isPendingFriendName(_ name: String) -> Bool {
        name == "配对码已创建" || name == "正在加入配对"
    }

    private static func defaultPetName(for instanceID: String?) -> String {
        instanceID?.lowercased() == "b" ? "团团2" : baseDefaultPetName
    }

    private static func makePairingCode() -> String {
        String((0..<4).compactMap { _ in pairingDigits.randomElement() })
    }

    private static func makeProfileID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func validProfileID(_ value: String) -> String? {
        value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) == nil ? nil : value
    }

    private static func isValidPairingCode(_ code: String) -> Bool {
        code.range(of: "^[0-9]{4}$", options: .regularExpression) != nil
            || code.range(of: "^[a-hj-km-np-z2-9]{8}$", options: .regularExpression) != nil
            || code.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func cleanName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(20))
    }

    private static func migrateLegacyDefaults(from legacyDomain: String, to defaults: UserDefaults) {
        guard !defaults.bool(forKey: legacyMigrationKey) else { return }
        let legacyValues = UserDefaults.standard.persistentDomain(forName: legacyDomain) ?? [:]
        for key in persistedKeys where defaults.object(forKey: key) == nil {
            if let value = legacyValues[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: legacyMigrationKey)
    }
}
