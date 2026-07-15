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
    var onPair: ((PetPeer) -> Void)?
    var onUnpair: (() -> Void)?
    var onScaleChange: ((PetScale) -> Void)?
    var onCreatePublicPairing: (() -> Void)?
    var onJoinPublicPairing: (() -> Void)?
    var nearbyPeers: [PetPeer] = []
    var friends: [PetPeer] = []
    var onlineFriendPeerIDs: Set<String> = []
    var onSelectFriend: ((PetPeer) -> Void)?
    var onRemoveFriend: (() -> Void)?
    var onEditProfile: (() -> Void)?
    var pairedFriend: PetPeer?
    var petName = "我的宠物"
    private var bubbleText: String?
    private var emotion: AppModel.Emotion = .idle
    private var frameIndex = BuddyFrames.initialIndex
    private var imageCache: [String: NSImage] = [:]
    private var petScale: PetScale = .normal

    override var isFlipped: Bool { true }

    func render(text: String?, emotion: AppModel.Emotion, frameName: String) {
        bubbleText = text
        self.emotion = emotion
        if let index = BuddyFrames.names.firstIndex(of: frameName) {
            frameIndex = index
        }
        needsDisplay = true
    }

    func setPetScale(_ scale: PetScale) {
        petScale = scale
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        frameIndex = BuddyFrames.nextIndex(after: frameIndex)
        needsDisplay = true
        onPoke?(BuddyFrames.names[frameIndex])
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let profileItem = NSMenuItem(title: "我的宠物：\(petName)", action: #selector(editProfile), keyEquivalent: "")
        menu.addItem(profileItem)
        let onlineCount = friends.filter { friend in
            guard let peerID = friend.peerID?.lowercased() else { return false }
            return onlineFriendPeerIDs.contains(peerID)
        }.count
        let friendsTitle = friends.isEmpty ? "好友（0）" : "好友（\(onlineCount)/\(friends.count) 在线）"
        let friendsItem = NSMenuItem(title: friendsTitle, action: nil, keyEquivalent: "")
        let friendsMenu = NSMenu()
        if friends.isEmpty {
            let empty = NSMenuItem(title: "还没有长期好友", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            friendsMenu.addItem(empty)
        } else {
            for friend in friends {
                let statusText: String
                let statusColor: NSColor
                if let peerID = friend.peerID?.lowercased() {
                    let isOnline = onlineFriendPeerIDs.contains(peerID)
                    statusText = isOnline ? "在线" : "离线"
                    statusColor = isOnline ? .systemGreen : .tertiaryLabelColor
                } else {
                    statusText = "状态未知"
                    statusColor = .tertiaryLabelColor
                }
                let item = NSMenuItem(title: "", action: #selector(selectFriend(_:)), keyEquivalent: "")
                let title = NSMutableAttributedString(
                    string: "●  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                        .foregroundColor: statusColor
                    ]
                )
                title.append(NSAttributedString(
                    string: "\(friend.name) · \(statusText)",
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
        friendsItem.submenu = friendsMenu
        menu.addItem(friendsItem)
        let addFriendItem = NSMenuItem(title: "添加好友", action: nil, keyEquivalent: "")
        let addFriendMenu = NSMenu()
        if let pairedFriend, pairedFriend.name == "配对码已创建" {
            let currentCodeItem = NSMenuItem(title: "配对码：\(pairedFriend.id)", action: nil, keyEquivalent: "")
            currentCodeItem.isEnabled = false
            addFriendMenu.addItem(currentCodeItem)
            addFriendMenu.addItem(NSMenuItem.separator())
        }
        let createItem = NSMenuItem(title: "生成配对码", action: #selector(createPublicPairing), keyEquivalent: "")
        createItem.target = self
        addFriendMenu.addItem(createItem)
        let joinItem = NSMenuItem(title: "输入配对码…", action: #selector(joinPublicPairing), keyEquivalent: "")
        joinItem.target = self
        addFriendMenu.addItem(joinItem)
        addFriendItem.submenu = addFriendMenu
        menu.addItem(addFriendItem)
        if !friends.isEmpty {
            let deleteItem = menu.addItem(withTitle: "删除好友…", action: #selector(removeFriend), keyEquivalent: "")
            deleteItem.attributedTitle = NSAttributedString(
                string: "删除好友…",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(NSMenuItem.separator())
        if let pairedFriend = confirmedFriend {
            let currentFriendItem = NSMenuItem(title: "当前好友：\(pairedFriend.name)", action: nil, keyEquivalent: "")
            currentFriendItem.isEnabled = false
            menu.addItem(currentFriendItem)
            menu.addItem(withTitle: "拍一拍 \(pairedFriend.name)", action: #selector(pokeFriend), keyEquivalent: "")
            menu.addItem(withTitle: "送一颗爱心", action: #selector(sendHeart), keyEquivalent: "")
            menu.addItem(withTitle: "一起庆祝", action: #selector(celebrate), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "断开连接", action: #selector(unpair), keyEquivalent: "")
        } else {
            let hint = NSMenuItem(title: "选择好友或添加新好友", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(NSMenuItem.separator())
        let scaleItem = NSMenuItem(title: "宠物大小", action: nil, keyEquivalent: "")
        let scaleMenu = NSMenu()
        for scale in PetScale.allCases {
            let item = NSMenuItem(title: scale.title, action: #selector(changeScale(_:)), keyEquivalent: "")
            item.tag = PetScale.allCases.firstIndex(of: scale) ?? 0
            item.state = scale == petScale ? .on : .off
            item.target = self
            scaleMenu.addItem(item)
        }
        scaleItem.submenu = scaleMenu
        menu.addItem(scaleItem)
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
        let scale = petScale.rawValue
        let size: CGFloat = 202 * scale
        let imageRect = NSRect(
            x: bounds.midX - size / 2,
            y: 42 * scale,
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
    @objc private func unpair() { onUnpair?() }
    @objc private func removeFriend() { onRemoveFriend?() }

    @objc private func pairPeer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let peer = nearbyPeers.first(where: { $0.id == id }) else { return }
        onPair?(peer)
    }

    @objc private func changeScale(_ sender: NSMenuItem) {
        let scales = PetScale.allCases
        guard scales.indices.contains(sender.tag) else { return }
        onScaleChange?(scales[sender.tag])
    }

    @objc private func createPublicPairing() { onCreatePublicPairing?() }
    @objc private func joinPublicPairing() { onJoinPublicPairing?() }

    @objc private func selectFriend(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let friend = friends.first(where: { $0.id == id }) else { return }
        onSelectFriend?(friend)
    }
    @objc private func editProfile() { onEditProfile?() }

    private var confirmedFriend: PetPeer? {
        guard let pairedFriend,
              pairedFriend.name != "配对码已创建",
              pairedFriend.name != "正在加入配对" else { return nil }
        return pairedFriend
    }
}
