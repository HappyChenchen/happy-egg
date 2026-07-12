import Foundation

@MainActor
final class AppModel {
    enum Emotion: Equatable {
        case idle
        case happy
    }

    private let service: any PetInteractionService
    private var listeningTask: Task<Void, Never>?

    private(set) var bubbleText: String?
    private(set) var emotion: Emotion = .idle
    private(set) var activeFrameName = BuddyFrames.names[BuddyFrames.initialIndex]
    var onStateChange: (() -> Void)?

    init(service: any PetInteractionService) {
        self.service = service
    }

    deinit {
        listeningTask?.cancel()
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

    func sendInteraction(kind: PetEvent.Kind, frameName: String? = nil) async {
        let selectedFrame = frameName ?? kind.defaultFrameName
        let safeFrame = BuddyFrames.names.contains(selectedFrame) ? selectedFrame : kind.defaultFrameName
        setState(text: kind.outgoingText, emotion: .happy, frameName: safeFrame)
        await service.send(PetEvent(kind: kind, senderName: "我", frameName: safeFrame))
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
}
