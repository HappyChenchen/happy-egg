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
            self?.model.interactLocally(frameName: frameName)
        } onSendAction: { [weak self] kind in
            Task { await self?.model.sendInteraction(kind: kind) }
        } onHide: { [weak self] in
            self?.hidePet()
        } onQuit: {
            NSApplication.shared.terminate(nil)
        } onScaleChange: { [weak self] scale in
            self?.model.setPetScale(scale)
        } onCopyPetCode: { [weak self] in
            self?.copyPetCode()
        } onAddFriend: { [weak self] in
            self?.promptForPetCode()
        } onResetPetCode: { [weak self] in
            self?.confirmResetPetCode()
        } onReviewFriendRequest: { [weak self] request in
            self?.reviewFriendRequest(request)
        } onSendMessage: { [weak self] in
            self?.promptForMessage()
        } onSendSticker: { [weak self] sticker in
            Task { await self?.model.sendMessage(kind: .sticker, body: sticker.identifier) }
        } onOpenMessage: { [weak self] message in
            self?.showMessageDetails(message)
        } onMarkMessagesRead: { [weak self] in
            self?.model.markAllMessagesRead()
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
            petCode: model.petCode,
            pendingFriendRequests: model.pendingFriendRequests,
            recentMessages: model.recentMessages,
            unreadMessageCount: model.unreadMessageCount,
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

    private func promptForPetCode() {
        let alert = NSAlert()
        alert.messageText = "添加好友"
        alert.informativeText = "输入朋友的 6 位永久宠物号，对方接受后成为好友"
        let input = NSTextField(string: NSPasteboard.general.string(forType: .string) ?? "")
        input.placeholderString = "例如 482913"
        input.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        input.controlSize = .large
        input.alignment = .center
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 32)
        alert.accessoryView = input
        alert.addButton(withTitle: "发送申请")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.sendFriendRequest(code: input.stringValue) }
    }

    private func promptForMessage() {
        guard let friend = model.confirmedFriend else { return }
        let online = model.isFriendOnline(friend)
        let alert = NSAlert()
        alert.messageText = "给 \(friend.name) 留言"
        alert.informativeText = online ? "对方在线，会马上收到。" : "对方当前离线，上线后会收到你的留言。"
        let input = NSTextField(string: "")
        input.placeholderString = "写点什么…"
        input.font = NSFont.systemFont(ofSize: 15)
        input.controlSize = .large
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 32)
        alert.accessoryView = input
        alert.addButton(withTitle: "发送")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.sendMessage(kind: .text, body: input.stringValue) }
    }

    private func showMessageDetails(_ message: PetMessage) {
        model.openMessage(message)
        let alert = NSAlert()
        alert.messageText = message.senderName
        alert.informativeText = message.kind == .text ? "收到的留言" : "收到的贴纸"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        switch message.kind {
        case .text:
            textView.string = message.body
        case .sticker:
            textView.alignment = .center
            textView.font = NSFont.systemFont(ofSize: 42)
            textView.string = PetSticker(rawValue: message.body)?.glyph ?? "🎁"
        }
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    private func copyPetCode() {
        guard let code = model.petCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func confirmResetPetCode() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更换宠物号？"
        alert.informativeText = "旧宠物号会立即失效，已有好友不会受影响。"
        alert.addButton(withTitle: "更换")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.resetPetCode() }
    }

    private func reviewFriendRequest(_ request: PetFriendRequest) {
        let alert = NSAlert()
        alert.messageText = "\(request.senderName) 想添加你为好友"
        alert.informativeText = "接受后，双方可以看到在线状态并互相互动。"
        alert.addButton(withTitle: "接受")
        alert.addButton(withTitle: "拒绝")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        Task { await model.respondToFriendRequest(request, accept: response == .alertFirstButtonReturn) }
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

    @objc private func copyPetCodeFromMenu() { copyPetCode() }
    @objc private func addFriendFromMenu() { promptForPetCode() }
    @objc private func resetPetCodeFromMenu() { confirmResetPetCode() }
    @objc private func reviewFriendRequestFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let request = model.pendingFriendRequests.first(where: { $0.id == id }) else { return }
        reviewFriendRequest(request)
    }
    @objc private func removeFriendFromMenu() { promptToRemoveFriend() }

    private func updateMenuState() {
        updateFriendMenus()
        if let friend = model.confirmedFriend {
            let isOnline = model.isFriendOnline(friend)
            pairingStatusItem?.title = "当前好友：\(friend.name) · \(isOnline ? "在线" : "离线")"
            interactionItem?.title = isOnline ? "拍一拍 \(friend.name)" : "\(friend.name) 不在线"
            interactionItem?.isEnabled = isOnline
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
        let codeItem = NSMenuItem(title: "我的宠物号：\(model.petCode ?? "获取中…")", action: nil, keyEquivalent: "")
        codeItem.isEnabled = false
        addFriendMenu.addItem(codeItem)
        let copyItem = NSMenuItem(title: "复制宠物号", action: #selector(copyPetCodeFromMenu), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = model.petCode != nil
        addFriendMenu.addItem(copyItem)
        let addItem = NSMenuItem(title: "输入宠物号…", action: #selector(addFriendFromMenu), keyEquivalent: "")
        addItem.target = self
        addFriendMenu.addItem(addItem)
        let resetItem = NSMenuItem(title: "更换宠物号…", action: #selector(resetPetCodeFromMenu), keyEquivalent: "")
        resetItem.target = self
        addFriendMenu.addItem(resetItem)
        if !model.pendingFriendRequests.isEmpty {
            addFriendMenu.addItem(NSMenuItem.separator())
            let requests = NSMenuItem(title: "好友申请（\(model.pendingFriendRequests.count)）", action: nil, keyEquivalent: "")
            let requestMenu = NSMenu()
            for request in model.pendingFriendRequests {
                let item = NSMenuItem(title: request.senderName, action: #selector(reviewFriendRequestFromMenu(_:)), keyEquivalent: "")
                item.representedObject = request.id
                item.target = self
                requestMenu.addItem(item)
            }
            requests.submenu = requestMenu
            addFriendMenu.addItem(requests)
        }
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
