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
    private static let authTokenKey = "com.macpet.auth-token"
    private static let petCodeKey = "com.macpet.pet-code"
    private static let messagesKey = "com.macpet.messages"
    private static let maxStoredMessages = 50
    private static let persistedKeys = [
        "com.macpet.peer-id",
        "com.macpet.pet-scale",
        "com.macpet.pet-name",
        "com.macpet.friends",
        selectedFriendKey,
        authTokenKey,
        petCodeKey
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
    private(set) var authToken: String
    private(set) var petCode: String?
    private(set) var pendingFriendRequests: [PetFriendRequest] = []
    private(set) var messages: [PetMessage] = []
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

    var unreadMessageCount: Int { messages.reduce(0) { $0 + ($1.isRead ? 0 : 1) } }

    /// Received messages ordered newest first for the friend message list.
    var recentMessages: [PetMessage] { messages.sorted { $0.receivedAt > $1.receivedAt } }

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
        let savedAuthToken = defaults.string(forKey: Self.authTokenKey)?.lowercased()
        authToken = savedAuthToken.flatMap(Self.validAuthToken) ?? Self.makeAuthToken()
        defaults.set(authToken, forKey: Self.authTokenKey)
        petCode = defaults.string(forKey: Self.petCodeKey).flatMap(Self.validPetCode)
        petScale = PetScale(rawValue: defaults.object(forKey: "com.macpet.pet-scale") as? CGFloat ?? 1) ?? .normal
        let savedPetName = defaults.string(forKey: "com.macpet.pet-name")
        petName = savedPetName == Self.legacyDefaultPetName ? fallbackPetName : (savedPetName ?? fallbackPetName)
        if savedPetName == Self.legacyDefaultPetName { defaults.set(fallbackPetName, forKey: "com.macpet.pet-name") }
        if let data = defaults.data(forKey: "com.macpet.friends"), let saved = try? JSONDecoder().decode([PetPeer].self, from: data) {
            friends = Self.deduplicatedFriends(saved).filter { !Self.isSelfFriend($0, peerID: peerID, petName: petName) }
            if friends != saved { persistFriends() }
        }
        if let data = defaults.data(forKey: Self.messagesKey), let saved = try? JSONDecoder().decode([PetMessage].self, from: data) {
            messages = Array(saved.suffix(Self.maxStoredMessages))
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
                case let .friendProfile(remotePeerID, name):
                    let normalizedPeerID = remotePeerID.lowercased()
                    guard let index = self.friends.firstIndex(where: { $0.peerID?.lowercased() == normalizedPeerID }) else { continue }
                    let oldFriend = self.friends[index]
                    guard oldFriend.name != name else { continue }
                    let renamedFriend = PetPeer(id: oldFriend.id, name: name, peerID: oldFriend.peerID)
                    self.friends[index] = renamedFriend
                    if self.pairedFriend?.peerID?.lowercased() == normalizedPeerID { self.pairedFriend = renamedFriend }
                    self.persistFriends()
                    self.onSocialStateChange?()
                    self.setState(text: "\(oldFriend.name) 改名为 \(name)", emotion: .happy, frameName: self.activeFrameName)
                case let .petCode(code):
                    guard let validCode = Self.validPetCode(code) else { continue }
                    self.petCode = validCode
                    self.defaults.set(validCode, forKey: Self.petCodeKey)
                    self.onSocialStateChange?()
                case let .friendRequest(request):
                    self.pendingFriendRequests.removeAll { $0.id == request.id }
                    self.pendingFriendRequests.append(request)
                    self.onSocialStateChange?()
                    self.setState(text: "收到 \(request.senderName) 的好友申请", emotion: .happy, frameName: self.activeFrameName)
                case let .friendRequestAccepted(requestID, peer):
                    self.pendingFriendRequests.removeAll { $0.id == requestID }
                    self.pairedFriend = peer
                    self.saveFriend(peer)
                    self.onSocialStateChange?()
                    self.setState(text: "已和 \(peer.name) 成为好友", emotion: .happy, frameName: self.activeFrameName)
                    Task { await self.service.acknowledgeFriendRequest(id: requestID) }
                case let .friendRequestRejected(requestID):
                    self.pendingFriendRequests.removeAll { $0.id == requestID }
                    self.onSocialStateChange?()
                    self.setState(text: "对方拒绝了好友申请", emotion: .idle, frameName: self.activeFrameName)
                    Task { await self.service.acknowledgeFriendRequest(id: requestID) }
                case let .friendRequestFailed(message):
                    self.setState(text: Self.friendRequestErrorText(message), emotion: .idle, frameName: self.activeFrameName)
                case let .friendRemoved(peerID):
                    guard let friend = self.friends.first(where: { $0.peerID?.lowercased() == peerID.lowercased() }) else { continue }
                    self.finishRemovingFriend(friend)
                case let .friendMessage(message):
                    self.receiveMessage(message)
                }
            }
        }
        refreshPresenceSubscription()
    }

    func removeFriend(_ friend: PetPeer) {
        guard let friendPeerID = friend.peerID?.lowercased() else {
            finishRemovingFriend(friend)
            return
        }
        let service = service
        Task { [weak self] in
            let removed = await service.removeFriend(peerID: friendPeerID)
            guard let self else { return }
            if removed {
                self.finishRemovingFriend(friend)
            } else {
                self.setState(text: "删除好友失败，请联网后重试", emotion: .idle, frameName: self.activeFrameName)
            }
        }
    }

    private func finishRemovingFriend(_ friend: PetPeer) {
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

    func sendFriendRequest(code: String) async {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let validCode = Self.validPetCode(normalized) else {
            setState(text: "请输入 6 位宠物号", emotion: .idle, frameName: activeFrameName)
            return
        }
        guard validCode != petCode else {
            setState(text: "不能添加自己的宠物", emotion: .idle, frameName: activeFrameName)
            return
        }
        let sent = await service.requestFriend(code: validCode)
        setState(
            text: sent ? "好友申请已发送" : "发送失败，正在重新连接",
            emotion: sent ? .happy : .idle,
            frameName: activeFrameName
        )
    }

    func respondToFriendRequest(_ request: PetFriendRequest, accept: Bool) async {
        guard pendingFriendRequests.contains(where: { $0.id == request.id }) else { return }
        let sent = await service.respondToFriendRequest(id: request.id, accept: accept)
        guard sent else {
            setState(text: "操作失败，请稍后重试", emotion: .idle, frameName: activeFrameName)
            return
        }
        if !accept {
            pendingFriendRequests.removeAll { $0.id == request.id }
            onSocialStateChange?()
            setState(text: "已拒绝好友申请", emotion: .idle, frameName: activeFrameName)
        }
    }

    func resetPetCode() async {
        let sent = await service.resetPetCode()
        setState(text: sent ? "正在更换宠物号" : "更换失败，请稍后重试", emotion: sent ? .happy : .idle, frameName: activeFrameName)
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

    /// Sends a short text note or preset sticker to the current friend. Unlike pokes,
    /// messages reach offline friends: the relay stores them until the friend returns.
    func sendMessage(kind: PetMessage.Kind, body: String) async {
        guard let friend = confirmedFriend, let targetPeerID = friend.peerID else {
            setState(text: "请选择好友后再留言", emotion: .idle, frameName: activeFrameName)
            return
        }
        let payload: String
        switch kind {
        case .text:
            let normalized = PetMessage.normalizedText(body)
            guard !normalized.isEmpty else {
                setState(text: "留言不能为空", emotion: .idle, frameName: activeFrameName)
                return
            }
            payload = normalized
        case .sticker:
            guard PetSticker(rawValue: body) != nil else {
                setState(text: "贴纸无效", emotion: .idle, frameName: activeFrameName)
                return
            }
            payload = body
        }
        let messageID = Self.makeProfileID()
        let result = await service.sendMessage(to: targetPeerID, messageID: messageID, kind: kind, body: payload)
        switch result {
        case .accepted:
            setState(
                text: outgoingMessageText(kind: kind, body: payload, friendName: friend.name),
                emotion: .happy,
                frameName: activeFrameName
            )
        case let .rejected(message):
            setState(text: Self.messageErrorText(message), emotion: .idle, frameName: activeFrameName)
        case .transportFailure:
            setState(text: "留言发送失败，正在重新连接", emotion: .idle, frameName: activeFrameName)
        }
    }

    /// Shows a stored message as a bubble and marks it read.
    func openMessage(_ message: PetMessage) {
        markMessageRead(message.id)
        setState(text: message.bubbleText(), emotion: .happy, frameName: activeFrameName)
    }

    func markAllMessagesRead() {
        guard messages.contains(where: { !$0.isRead }) else { return }
        for index in messages.indices { messages[index].isRead = true }
        persistMessages()
        onSocialStateChange?()
    }

    private func receiveMessage(_ message: PetMessage) {
        let resolved = resolvedSenderMessage(message)
        if messages.contains(where: { $0.id == resolved.id }) {
            Task { await service.acknowledgeMessage(id: resolved.id) }
            return
        }
        messages.append(resolved)
        messages.sort { $0.receivedAt < $1.receivedAt }
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
        persistMessages()
        onSocialStateChange?()
        setState(text: resolved.bubbleText(), emotion: .happy, frameName: activeFrameName)
        Task { await service.acknowledgeMessage(id: resolved.id) }
    }

    /// Prefers the locally saved friend name over the name carried on the wire.
    private func resolvedSenderMessage(_ message: PetMessage) -> PetMessage {
        guard let name = friends.first(where: { $0.peerID?.lowercased() == message.senderPeerID.lowercased() })?.name,
              name != message.senderName else { return message }
        return PetMessage(
            id: message.id,
            senderPeerID: message.senderPeerID,
            senderName: name,
            kind: message.kind,
            body: message.body,
            receivedAt: message.receivedAt,
            isRead: message.isRead
        )
    }

    private func markMessageRead(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }), !messages[index].isRead else { return }
        messages[index].isRead = true
        persistMessages()
        onSocialStateChange?()
    }

    private func persistMessages() {
        if let data = try? JSONEncoder().encode(messages) { defaults.set(data, forKey: Self.messagesKey) }
    }

    private func outgoingMessageText(kind: PetMessage.Kind, body: String, friendName: String) -> String {
        switch kind {
        case .text: "已给 \(friendName) 留言"
        case .sticker: "已发给 \(friendName) \(PetSticker(rawValue: body)?.glyph ?? "🎁")"
        }
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
            await service.updatePresence(
                peerID: localPeerID,
                authToken: self.authToken,
                name: localPetName,
                friendPeerIDs: friendPeerIDs
            )
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

    private static func makeAuthToken() -> String {
        makeProfileID() + makeProfileID()
    }

    private static func validProfileID(_ value: String) -> String? {
        value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) == nil ? nil : value
    }

    private static func validAuthToken(_ value: String) -> String? {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil ? nil : value
    }

    private static func validPetCode(_ value: String) -> String? {
        value.range(of: "^[0-9]{6}$", options: .regularExpression) == nil ? nil : value
    }

    private static func friendRequestErrorText(_ message: String) -> String {
        switch message {
        case "pet code not found": "没有找到这个宠物号"
        case "cannot add yourself": "不能添加自己的宠物"
        default: "好友申请失败，请稍后重试"
        }
    }

    private static func messageErrorText(_ message: String) -> String {
        switch message {
        case "not friends": "对方不是你的好友"
        case "rate limit": "留言太频繁，请稍后再试"
        case "authentication required": "身份未就绪，请稍后重试"
        default: "留言发送失败，请稍后重试"
        }
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
