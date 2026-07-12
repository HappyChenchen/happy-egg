import AppKit

final class PetView: NSView {
    private static let imageBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "MacPet_MacPet", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    var onPoke: ((String) -> Void)?
    var onSendAction: ((PetEvent.Kind) -> Void)?
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?
    private var bubbleText: String?
    private var emotion: AppModel.Emotion = .idle
    private var frameIndex = BuddyFrames.initialIndex
    private var imageCache: [String: NSImage] = [:]

    override var isFlipped: Bool { true }

    func render(text: String?, emotion: AppModel.Emotion, frameName: String) {
        bubbleText = text
        self.emotion = emotion
        if let index = BuddyFrames.names.firstIndex(of: frameName) {
            frameIndex = index
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        frameIndex = BuddyFrames.nextIndex(after: frameIndex)
        needsDisplay = true
        onPoke?(BuddyFrames.names[frameIndex])
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "拍一拍朋友", action: #selector(pokeFriend), keyEquivalent: "")
        menu.addItem(withTitle: "送一颗爱心", action: #selector(sendHeart), keyEquivalent: "")
        menu.addItem(withTitle: "一起庆祝", action: #selector(celebrate), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "隐藏宠物", action: #selector(hidePet), keyEquivalent: "")
        menu.addItem(withTitle: "关闭 MacPet", action: #selector(quitApp), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let bubbleText {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let textSize = bubbleText.size(withAttributes: attributes)
            let bubbleRect = NSRect(x: bounds.midX - textSize.width / 2 - 10, y: 12, width: textSize.width + 20, height: 28)
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: bubbleRect, xRadius: 14, yRadius: 14).fill()
            bubbleText.draw(at: NSPoint(x: bubbleRect.minX + 10, y: bubbleRect.minY + 7), withAttributes: attributes)
        }

        guard let image = currentImage else { return }
        // Keep the character anchored while feedback appears. Only the speech
        // bubble and selected frame change, so a poke never looks like a jump.
        let size: CGFloat = 202
        let imageRect = NSRect(
            x: bounds.midX - size / 2,
            y: 42,
            width: size,
            height: size
        )
        image.draw(in: imageRect)
    }

    private var currentImage: NSImage? {
        let name = BuddyFrames.names[frameIndex]
        if let cached = imageCache[name] { return cached }
        guard let url = Self.imageBundle.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        imageCache[name] = image
        return image
    }

    @objc private func pokeFriend() { onSendAction?(.poke) }
    @objc private func sendHeart() { onSendAction?(.heart) }
    @objc private func celebrate() { onSendAction?(.celebrate) }
    @objc private func hidePet() { onHide?() }
    @objc private func quitApp() { onQuit?() }
}
