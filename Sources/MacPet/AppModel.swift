import Foundation

@MainActor
final class AppModel {
    enum Emotion: Equatable {
        case idle
        case happy
    }

    private let service: any PetInteractionService
    private var listeningTask: Task<Void, Never>?
    private var peerRefreshTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private(set) var bubbleText: String?
    private(set) var emotion: Emotion = .idle
    private(set) var activeFrameName = BuddyFrames.names[BuddyFrames.initialIndex]
    private(set) var nearbyPeers: [PetPeer] = []
    private(set) var pairedFriend: PetPeer?
    private(set) var petScale: PetScale
    var onStateChange: (() -> Void)?
    var onPeersChange: (() -> Void)?
    var onScaleChange: (() -> Void)?

    init(service: any PetInteractionService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        petScale = PetScale(rawValue: defaults.object(forKey: "com.macpet.pet-scale") as? CGFloat ?? 1) ?? .normal
    }

    deinit {
        listeningTask?.cancel()
        peerRefreshTask?.cancel()
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
    }

    func setPetScale(_ scale: PetScale) {
        petScale = scale
        defaults.set(Double(scale.rawValue), forKey: "com.macpet.pet-scale")
        onScaleChange?()
    }

    func sendInteraction(kind: PetEvent.Kind, frameName: String? = nil) async {
        let selectedFrame = frameName ?? kind.defaultFrameName
        let safeFrame = BuddyFrames.names.contains(selectedFrame) ? selectedFrame : kind.defaultFrameName
        guard let pairedFriend else {
            setState(text: "本地互动成功，配对后可拍朋友", emotion: .happy, frameName: safeFrame)
            return
        }
        setState(text: outgoingText(for: kind, friendName: pairedFriend.name), emotion: .happy, frameName: safeFrame)
        await service.send(PetEvent(kind: kind, senderName: "我", frameName: safeFrame), to: pairedFriend.id)
    }

    private func receive(_ event: PetEvent) {
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
}
