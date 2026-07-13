import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(service: PublicPetInteractionService())
    private var panelController: PetPanelController!
    private var statusItem: NSStatusItem!
    private var visibilityItem: NSMenuItem!
    private var pairingStatusItem: NSMenuItem!
    private var interactionItem: NSMenuItem!
    private var isPetVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PetPanelController { [weak self] frameName in
            Task { await self?.model.sendInteraction(kind: .poke, frameName: frameName) }
        } onSendAction: { [weak self] kind in
            Task { await self?.model.sendInteraction(kind: kind) }
        } onHide: { [weak self] in
            self?.hidePet()
        } onQuit: {
            NSApplication.shared.terminate(nil)
        } onPair: { [weak self] peer in
            self?.model.pair(with: peer)
        } onUnpair: { [weak self] in
            self?.model.unpair()
        } onScaleChange: { [weak self] scale in
            self?.model.setPetScale(scale)
        } onCreatePublicPairing: { [weak self] in
            Task {
                guard let self else { return }
                let code = await self.model.createPublicPairing()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        } onJoinPublicPairing: { [weak self] in
            guard let code = NSPasteboard.general.string(forType: .string) else { return }
            Task { await self?.model.joinPublicPairing(code: code) }
        }
        model.onStateChange = { [weak self] in self?.renderPet() }
        model.onPeersChange = { [weak self] in self?.updateMenuState(); self?.renderPet() }
        model.onScaleChange = { [weak self] in self?.panelController.setPetScale(self?.model.petScale ?? .normal) }
        renderPet()
        panelController.setPetScale(model.petScale)
        showPet()
        model.startListening()
        model.startRefreshingPeers()
        configureMenuBar()
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "我的宠物", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        pairingStatusItem = NSMenuItem(title: "公网模式 · 尚未配对", action: nil, keyEquivalent: "")
        pairingStatusItem.isEnabled = false
        menu.addItem(pairingStatusItem)
        interactionItem = menu.addItem(withTitle: "请先右键宠物配对", action: #selector(pokeFriend), keyEquivalent: "p")
        visibilityItem = menu.addItem(withTitle: "隐藏宠物", action: #selector(togglePetVisibility), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 MacPet", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        updateMenuState()
    }

    private func renderPet() {
        panelController.render(
            text: model.bubbleText,
            emotion: model.emotion,
            frameName: model.activeFrameName,
            peers: model.nearbyPeers,
            pairedFriend: model.pairedFriend
        )
    }

    @objc private func pokeFriend() { Task { await model.sendInteraction(kind: .poke) } }

    private func updateMenuState() {
        if let friend = model.confirmedFriend {
            pairingStatusItem?.title = "已配对 · \(friend.name)"
            interactionItem?.title = "拍一拍 \(friend.name)"
            interactionItem?.isEnabled = true
        } else if model.pairedFriend?.name == "配对码已创建" {
            pairingStatusItem?.title = "公网配对 · 等待朋友加入"
            interactionItem?.title = "等待朋友加入后可互动"
            interactionItem?.isEnabled = false
        } else if model.pairedFriend?.name == "正在加入配对" {
            pairingStatusItem?.title = "公网配对 · 正在加入"
            interactionItem?.title = "等待配对确认"
            interactionItem?.isEnabled = false
        } else {
            pairingStatusItem?.title = "公网模式 · 尚未配对"
            interactionItem?.title = "请先右键宠物配对"
            interactionItem?.isEnabled = false
        }
    }
    private func showPet() {
        panelController.show()
        isPetVisible = true
        updateVisibilityItem()
    }

    private func hidePet() {
        panelController.hide()
        isPetVisible = false
        updateVisibilityItem()
    }

    private func updateVisibilityItem() {
        visibilityItem?.title = isPetVisible ? "隐藏宠物" : "显示宠物"
    }

    @objc private func togglePetVisibility() {
        isPetVisible ? hidePet() : showPet()
    }

    private func statusBarIcon() -> NSImage? {
        let bundle: Bundle
        if let url = Bundle.main.url(forResource: "MacPet_MacPet", withExtension: "bundle"), let packagedBundle = Bundle(url: url) {
            bundle = packagedBundle
        } else {
            bundle = .module
        }
        guard let url = bundle.url(forResource: "ai_buddy_05", withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        icon.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 18, height: 18),
            from: NSRect(x: 70, y: 100, width: 280, height: 280),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        icon.unlockFocus()
        icon.isTemplate = false
        return icon
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
