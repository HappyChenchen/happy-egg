import AppKit

@MainActor
final class PetPanelController {
    private static let baseSize = NSSize(width: 220, height: 250)
    private let panel: NSPanel
    private let petView: PetView

    init(
        onLocalInteraction: @escaping (String) -> Void,
        onSendAction: @escaping (PetEvent.Kind) -> Void,
        onHide: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onScaleChange: @escaping (PetScale) -> Void,
        onCopyPetCode: @escaping () -> Void,
        onAddFriend: @escaping () -> Void,
        onResetPetCode: @escaping () -> Void,
        onReviewFriendRequest: @escaping (PetFriendRequest) -> Void,
        onSelectFriend: @escaping (PetPeer) -> Void,
        onRemoveFriend: @escaping () -> Void,
        onEditProfile: @escaping () -> Void
    ) {
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
        petView.onLocalInteraction = onLocalInteraction
        petView.onSendAction = onSendAction
        petView.onHide = onHide
        petView.onQuit = onQuit
        petView.onScaleChange = onScaleChange
        petView.onCopyPetCode = onCopyPetCode
        petView.onAddFriend = onAddFriend
        petView.onResetPetCode = onResetPetCode
        petView.onReviewFriendRequest = onReviewFriendRequest
        petView.onSelectFriend = onSelectFriend
        petView.onRemoveFriend = onRemoveFriend
        petView.onEditProfile = onEditProfile
        panel = NSPanel(
            contentRect: NSRect(x: 140, y: 140, width: 220, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = petView
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func setOrigin(_ origin: NSPoint) { panel.setFrameOrigin(origin) }
    func render(text: String?, emotion: AppModel.Emotion, frameName: String, petName: String, petCode: String?, pendingFriendRequests: [PetFriendRequest], friends: [PetPeer], onlineFriendPeerIDs: Set<String>, pairedFriend: PetPeer?) {
        petView.friends = friends
        petView.onlineFriendPeerIDs = onlineFriendPeerIDs
        petView.pairedFriend = pairedFriend
        petView.petName = petName
        petView.petCode = petCode
        petView.pendingFriendRequests = pendingFriendRequests
        petView.render(text: text, emotion: emotion, frameName: frameName)
    }

    func setPetScale(_ scale: PetScale) {
        petView.setPetScale(scale)
        let newSize = NSSize(width: Self.baseSize.width * scale.rawValue, height: Self.baseSize.height * scale.rawValue)
        let oldFrame = panel.frame
        let newFrame = NSRect(x: oldFrame.midX - newSize.width / 2, y: oldFrame.midY - newSize.height / 2, width: newSize.width, height: newSize.height)
        panel.setFrame(newFrame, display: true, animate: true)
        petView.frame = NSRect(origin: .zero, size: newSize)
    }
}
