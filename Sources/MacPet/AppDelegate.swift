import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchInstanceID = AppModel.launchInstanceID()
    private let model: AppModel

    override init() {
        model = AppModel(
            service: PublicPetInteractionService(),
            defaults: AppModel.launchDefaults(),
            instanceID: launchInstanceID
        )
        super.init()
    }
    private var panelController: PetPanelController!
    private var statusItem: NSStatusItem!
    private var visibilityItem: NSMenuItem!
    private var pairingStatusItem: NSMenuItem!
    private var interactionItem: NSMenuItem!
    private var profileItem: NSMenuItem!
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
            self?.promptForPairingCode()
        } onSelectFriend: { [weak self] friend in
            Task { await self?.model.selectFriend(friend) }
        } onEditProfile: { [weak self] in
            self?.editProfile()
        }
        panelController.setOrigin(panelOrigin())
        model.onStateChange = { [weak self] in self?.renderPet(); self?.updateProfileMenuItem() }
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
        profileItem = menu.addItem(withTitle: "我的宠物：\(model.petName)", action: nil, keyEquivalent: "")
        profileItem.isEnabled = false
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

    private func updateProfileMenuItem() {
        profileItem?.title = "我的宠物：\(model.petName)"
    }

    private func panelOrigin() -> NSPoint {
        switch launchInstanceID {
        case "a": NSPoint(x: 140, y: 160)
        case "b": NSPoint(x: 420, y: 160)
        default: NSPoint(x: 140, y: 140)
        }
    }

    private func renderPet() {
        panelController.render(
            text: model.bubbleText,
            emotion: model.emotion,
            frameName: model.activeFrameName,
            petName: model.petName,
            peers: model.nearbyPeers,
            friends: model.friends,
            pairedFriend: model.pairedFriend
        )
    }

    private func editProfile() {
        let alert = NSAlert()
        alert.messageText = "我的宠物"
        alert.informativeText = "给宠物取一个名字"
        let pet = NSTextField(string: model.petName)
        pet.font = NSFont.systemFont(ofSize: 16)
        pet.controlSize = .large
        pet.translatesAutoresizingMaskIntoConstraints = false
        pet.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [NSTextField(labelWithString: "宠物名字"), pet])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.setProfile(owner: model.ownerName, pet: pet.stringValue) }
    }

    private func promptForPairingCode() {
        let alert = NSAlert()
        alert.messageText = "加入配对"
        alert.informativeText = "输入朋友发来的 8 位配对码"
        let input = NSTextField(string: NSPasteboard.general.string(forType: .string) ?? "")
        input.placeholderString = "例如 abcdef23"
        input.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        input.controlSize = .large
        input.alignment = .center
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 32)
        alert.accessoryView = input
        alert.addButton(withTitle: "加入")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.joinPublicPairing(code: input.stringValue) }
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
