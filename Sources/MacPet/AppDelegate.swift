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
    private var friendsItem: NSMenuItem!
    private var addFriendItem: NSMenuItem!
    private var removeFriendItem: NSMenuItem!
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
        } onScaleChange: { [weak self] scale in
            self?.model.setPetScale(scale)
        } onCreatePublicPairing: { [weak self] in
            self?.createAndCopyPairingCode()
        } onJoinPublicPairing: { [weak self] in
            self?.promptForPairingCode()
        } onSelectFriend: { [weak self] friend in
            Task { await self?.model.selectFriend(friend) }
        } onRemoveFriend: { [weak self] in
            self?.promptToRemoveFriend()
        } onEditProfile: { [weak self] in
            self?.editProfile()
        }
        panelController.setOrigin(panelOrigin())
        model.onStateChange = { [weak self] in self?.renderPet(); self?.updateProfileMenuItem() }
        model.onSocialStateChange = { [weak self] in self?.updateMenuState(); self?.renderPet() }
        model.onScaleChange = { [weak self] in self?.panelController.setPetScale(self?.model.petScale ?? .normal) }
        renderPet()
        panelController.setPetScale(model.petScale)
        showPet()
        model.startListening()
        configureMenuBar()
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusBarIcon()
        let menu = NSMenu()
        profileItem = menu.addItem(withTitle: "我的宠物：\(model.petName)", action: nil, keyEquivalent: "")
        profileItem.isEnabled = false
        menu.addItem(NSMenuItem.separator())
        friendsItem = NSMenuItem(title: "好友", action: nil, keyEquivalent: "")
        menu.addItem(friendsItem)
        addFriendItem = NSMenuItem(title: "添加好友", action: nil, keyEquivalent: "")
        menu.addItem(addFriendItem)
        removeFriendItem = menu.addItem(withTitle: "删除好友…", action: #selector(removeFriendFromMenu), keyEquivalent: "")
        removeFriendItem.attributedTitle = NSAttributedString(
            string: "删除好友…",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(NSMenuItem.separator())
        pairingStatusItem = NSMenuItem(title: "尚未选择好友", action: nil, keyEquivalent: "")
        pairingStatusItem.isEnabled = false
        menu.addItem(pairingStatusItem)
        interactionItem = menu.addItem(withTitle: "选择好友后可互动", action: #selector(pokeFriend), keyEquivalent: "p")
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
            friends: model.friends,
            onlineFriendPeerIDs: model.onlineFriendPeerIDs,
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
        if alert.runModal() == .alertFirstButtonReturn { model.setPetName(pet.stringValue) }
    }

    private func promptForPairingCode() {
        let alert = NSAlert()
        alert.messageText = "加入配对"
        alert.informativeText = "输入朋友发来的 4 位数字配对码"
        let input = NSTextField(string: NSPasteboard.general.string(forType: .string) ?? "")
        input.placeholderString = "例如 2048"
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

    private func createAndCopyPairingCode() {
        Task {
            let code = await model.createPublicPairing()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }

    private func promptToRemoveFriend() {
        guard !model.friends.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除好友"
        alert.informativeText = "删除后需要重新配对才能互动。"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 30), pullsDown: false)
        for friend in model.friends {
            let state = model.isFriendOnline(friend) ? "在线" : "离线"
            picker.addItem(withTitle: "\(friend.name) · \(state)")
            picker.lastItem?.representedObject = friend.id
        }
        alert.accessoryView = picker
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let friendID = picker.selectedItem?.representedObject as? String,
              let friend = model.friends.first(where: { $0.id == friendID }) else { return }
        model.removeFriend(friend)
    }

    @objc private func pokeFriend() { Task { await model.sendInteraction(kind: .poke) } }

    @objc private func selectStatusFriend(_ sender: NSMenuItem) {
        guard let friendID = sender.representedObject as? String,
              let friend = model.friends.first(where: { $0.id == friendID }) else { return }
        Task { await model.selectFriend(friend) }
    }

    @objc private func createPairingCodeFromMenu() { createAndCopyPairingCode() }
    @objc private func joinPairingFromMenu() { promptForPairingCode() }
    @objc private func removeFriendFromMenu() { promptToRemoveFriend() }

    private func updateMenuState() {
        updateFriendMenus()
        if let friend = model.confirmedFriend {
            let isOnline = model.isFriendOnline(friend)
            pairingStatusItem?.title = "当前好友：\(friend.name) · \(isOnline ? "在线" : "离线")"
            interactionItem?.title = isOnline ? "拍一拍 \(friend.name)" : "\(friend.name) 不在线"
            interactionItem?.isEnabled = isOnline
        } else if let code = model.activePairingCode {
            pairingStatusItem?.title = "配对码：" + code
            interactionItem?.title = "等待好友加入"
            interactionItem?.isEnabled = false
        } else if model.pairedFriend?.name == "正在加入配对" {
            pairingStatusItem?.title = "正在加入好友…"
            interactionItem?.title = "等待好友确认"
            interactionItem?.isEnabled = false
        } else {
            pairingStatusItem?.title = "尚未选择好友"
            interactionItem?.title = "选择好友后可互动"
            interactionItem?.isEnabled = false
        }
    }

    private func updateFriendMenus() {
        let friendsMenu = NSMenu()
        if model.friends.isEmpty {
            let emptyItem = NSMenuItem(title: "还没有好友", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            friendsMenu.addItem(emptyItem)
        } else {
            for friend in model.friends {
                let online = model.isFriendOnline(friend)
                let item = NSMenuItem(title: "", action: #selector(selectStatusFriend(_:)), keyEquivalent: "")
                let title = NSMutableAttributedString(
                    string: "●  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                        .foregroundColor: online ? NSColor.systemGreen : NSColor.tertiaryLabelColor
                    ]
                )
                title.append(NSAttributedString(
                    string: "\(friend.name) · \(online ? "在线" : "离线")",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.labelColor
                    ]
                ))
                item.attributedTitle = title
                item.representedObject = friend.id
                item.target = self
                friendsMenu.addItem(item)
            }
        }
        friendsItem?.title = model.friends.isEmpty ? "好友（0）" : "好友（\(model.friends.count)）"
        friendsItem?.submenu = friendsMenu

        let addFriendMenu = NSMenu()
        if let code = model.activePairingCode {
            let codeItem = NSMenuItem(title: "配对码：\(code)", action: nil, keyEquivalent: "")
            codeItem.isEnabled = false
            addFriendMenu.addItem(codeItem)
            addFriendMenu.addItem(NSMenuItem.separator())
        }
        let createItem = NSMenuItem(title: "生成配对码", action: #selector(createPairingCodeFromMenu), keyEquivalent: "")
        createItem.target = self
        addFriendMenu.addItem(createItem)
        let joinItem = NSMenuItem(title: "输入配对码…", action: #selector(joinPairingFromMenu), keyEquivalent: "")
        joinItem.target = self
        addFriendMenu.addItem(joinItem)
        addFriendItem?.submenu = addFriendMenu
        removeFriendItem?.isEnabled = !model.friends.isEmpty
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
