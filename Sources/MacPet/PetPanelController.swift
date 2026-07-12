import AppKit

@MainActor
final class PetPanelController {
    private static let baseSize = NSSize(width: 220, height: 250)
    private let panel: NSPanel
    private let petView: PetView

    init(
        onPoke: @escaping (String) -> Void,
        onSendAction: @escaping (PetEvent.Kind) -> Void,
        onHide: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onPair: @escaping (PetPeer) -> Void,
        onUnpair: @escaping () -> Void,
        onScaleChange: @escaping (PetScale) -> Void
    ) {
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
        petView.onPoke = onPoke
        petView.onSendAction = onSendAction
        petView.onHide = onHide
        petView.onQuit = onQuit
        petView.onPair = onPair
        petView.onUnpair = onUnpair
        petView.onScaleChange = onScaleChange
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
    func render(text: String?, emotion: AppModel.Emotion, frameName: String, peers: [PetPeer], pairedFriend: PetPeer?) {
        petView.nearbyPeers = peers
        petView.pairedFriend = pairedFriend
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
