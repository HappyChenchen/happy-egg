import AppKit

@MainActor
final class PetPanelController {
    private let panel: NSPanel
    private let petView: PetView

    init(
        onPoke: @escaping (String) -> Void,
        onSendAction: @escaping (PetEvent.Kind) -> Void,
        onHide: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
        petView.onPoke = onPoke
        petView.onSendAction = onSendAction
        petView.onHide = onHide
        petView.onQuit = onQuit
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
    func render(text: String?, emotion: AppModel.Emotion, frameName: String) {
        petView.render(text: text, emotion: emotion, frameName: frameName)
    }
}
