import AppKit

final class PetView: NSView {
    private static let defaultSingleClickDelay: TimeInterval = 0.22
    private static let maximumBubbleTextHeight: CGFloat = 64
    private static let imageBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "MacPet_MacPet", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    var onLocalInteraction: ((String) -> Void)?
    var onSendAction: ((PetEvent.Kind) -> Void)?
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?
    var onScaleChange: ((PetScale) -> Void)?
    var onCopyPetCode: (() -> Void)?
    var onAddFriend: (() -> Void)?
    var onResetPetCode: (() -> Void)?
    var onReviewFriendRequest: ((PetFriendRequest) -> Void)?
    var onSendMessage: (() -> Void)?
    var onSendSticker: ((PetSticker) -> Void)?
    var onOpenMessage: ((PetMessage) -> Void)?
    var onMarkMessagesRead: (() -> Void)?
    var friends: [PetPeer] = []
    var onlineFriendPeerIDs: Set<String> = []
    var onSelectFriend: ((PetPeer) -> Void)?
    var onRemoveFriend: (() -> Void)?
    var onEditProfile: (() -> Void)?
    var pairedFriend: PetPeer?
    var petName = "我的宠物"
    var petCode: String?
    var pendingFriendRequests: [PetFriendRequest] = []
    var recentMessages: [PetMessage] = []
    var unreadMessageCount = 0
    private var bubbleText: String?
    private var emotion: AppModel.Emotion = .idle
    private var frameIndex = BuddyFrames.initialIndex
    private var imageCache: [String: NSImage] = [:]
    private var petScale: PetScale = .normal
    private var pendingSingleClick: DispatchWorkItem?
    private let singleClickDelay: TimeInterval
    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    static func bubbleLayout(for text: String, in bounds: NSRect) -> (bubbleRect: NSRect, textRect: NSRect) {
        let maximumBubbleWidth = max(44, bounds.width - 16)
        let maximumTextWidth = max(24, maximumBubbleWidth - 20)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bubbleAttributes
        )
        let textWidth = min(maximumTextWidth, max(24, ceil(measured.width)))
        let textHeight = min(maximumBubbleTextHeight, max(14, ceil(measured.height)))
        let bubbleWidth = min(maximumBubbleWidth, textWidth + 20)
        let bubbleHeight = max(28, textHeight + 14)
        let centeredX = bounds.midX - bubbleWidth / 2
        let bubbleX = min(max(bounds.minX, centeredX), bounds.maxX - bubbleWidth)
        let bubbleRect = NSRect(x: bubbleX, y: 12, width: bubbleWidth, height: bubbleHeight)
        let textRect = NSRect(
            x: bubbleRect.minX + 10,
            y: bubbleRect.minY + 7,
            width: bubbleRect.width - 20,
            height: bubbleRect.height - 14
        )
        return (bubbleRect, textRect)
    }

    private static var bubbleAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    init(frame frameRect: NSRect, singleClickDelay: TimeInterval = PetView.defaultSingleClickDelay) {
        self.singleClickDelay = singleClickDelay
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        singleClickDelay = Self.defaultSingleClickDelay
        super.init(coder: coder)
    }

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
        mouseDownLocation = event.locationInWindow
        didDrag = false
        guard event.clickCount >= 2 else { return }
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if movedBeyondClickThreshold(to: event.locationInWindow) {
            didDrag = true
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            didDrag = false
        }
        guard !didDrag,
              !movedBeyondClickThreshold(to: event.locationInWindow) else { return }
        if event.clickCount == 2 {
            onSendAction?(.poke)
            return
        }
        guard event.clickCount == 1 else { return }
        pendingSingleClick?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.frameIndex = BuddyFrames.nextIndex(after: self.frameIndex)
            self.needsDisplay = true
            self.onLocalInteraction?(BuddyFrames.names[self.frameIndex])
            self.pendingSingleClick = nil
        }
        pendingSingleClick = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + singleClickDelay, execute: workItem)
    }

    private func movedBeyondClickThreshold(to location: NSPoint) -> Bool {
        guard let mouseDownLocation else { return false }
        return hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y) > 4
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
        let codeItem = NSMenuItem(title: "我的宠物号：\(petCode ?? "获取中…")", action: nil, keyEquivalent: "")
        codeItem.isEnabled = false
        addFriendMenu.addItem(codeItem)
        let copyItem = NSMenuItem(title: "复制宠物号", action: #selector(copyPetCode), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = petCode != nil
        addFriendMenu.addItem(copyItem)
        let addItem = addFriendMenu.addItem(withTitle: "输入宠物号…", action: #selector(addFriend), keyEquivalent: "")
        addItem.target = self
        let resetItem = addFriendMenu.addItem(withTitle: "更换宠物号…", action: #selector(resetPetCode), keyEquivalent: "")
        resetItem.target = self
        addFriendItem.submenu = addFriendMenu
        menu.addItem(addFriendItem)
        if !pendingFriendRequests.isEmpty {
            let requestsItem = NSMenuItem(title: "好友申请（\(pendingFriendRequests.count)）", action: nil, keyEquivalent: "")
            let requestsMenu = NSMenu()
            for request in pendingFriendRequests {
                let item = NSMenuItem(title: request.senderName, action: #selector(reviewFriendRequest(_:)), keyEquivalent: "")
                item.representedObject = request.id
                item.target = self
                requestsMenu.addItem(item)
            }
            requestsItem.submenu = requestsMenu
            menu.addItem(requestsItem)
        }
        if !recentMessages.isEmpty {
            let title = unreadMessageCount > 0 ? "消息记录（\(unreadMessageCount) 未读）" : "消息记录"
            let messagesItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let messagesMenu = NSMenu()
            for message in recentMessages.prefix(12) {
                let item = NSMenuItem(title: "", action: #selector(openMessage(_:)), keyEquivalent: "")
                let dot = NSMutableAttributedString(
                    string: message.isRead ? "○  " : "●  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                        .foregroundColor: message.isRead ? NSColor.tertiaryLabelColor : NSColor.systemBlue
                    ]
                )
                dot.append(NSAttributedString(
                    string: "\(message.senderName)：\(String(message.preview.prefix(18)))",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: message.isRead ? .regular : .medium),
                        .foregroundColor: NSColor.labelColor
                    ]
                ))
                item.attributedTitle = dot
                item.representedObject = message.id
                item.target = self
                messagesMenu.addItem(item)
            }
            messagesMenu.addItem(NSMenuItem.separator())
            let readAll = messagesMenu.addItem(withTitle: "全部标为已读", action: #selector(markMessagesRead), keyEquivalent: "")
            readAll.target = self
            readAll.isEnabled = unreadMessageCount > 0
            messagesItem.submenu = messagesMenu
            menu.addItem(messagesItem)
        }
        if !friends.isEmpty {
            let deleteItem = menu.addItem(withTitle: "删除好友…", action: #selector(removeFriend), keyEquivalent: "")
            deleteItem.attributedTitle = NSAttributedString(
                string: "删除好友…",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(NSMenuItem.separator())
        if let pairedFriend = confirmedFriend {
            let isOnline = pairedFriend.peerID.map { onlineFriendPeerIDs.contains($0.lowercased()) } ?? false
            let currentFriendItem = NSMenuItem(
                title: "当前好友：\(pairedFriend.name) · \(isOnline ? "在线" : "离线")",
                action: nil,
                keyEquivalent: ""
            )
            currentFriendItem.isEnabled = false
            menu.addItem(currentFriendItem)
            if isOnline {
                menu.addItem(withTitle: "拍一拍 \(pairedFriend.name)", action: #selector(pokeFriend), keyEquivalent: "")
                menu.addItem(withTitle: "送一颗爱心", action: #selector(sendHeart), keyEquivalent: "")
                menu.addItem(withTitle: "一起庆祝", action: #selector(celebrate), keyEquivalent: "")
            } else {
                let unavailableItem = NSMenuItem(title: "好友不在线，可留言或送贴纸", action: nil, keyEquivalent: "")
                unavailableItem.isEnabled = false
                menu.addItem(unavailableItem)
            }
            menu.addItem(withTitle: "给 \(pairedFriend.name) 留言…", action: #selector(sendMessage), keyEquivalent: "")
            let stickerItem = NSMenuItem(title: "送贴纸给 \(pairedFriend.name)", action: nil, keyEquivalent: "")
            let stickerMenu = NSMenu()
            for sticker in PetSticker.allCases {
                let item = NSMenuItem(title: "\(sticker.glyph)  \(sticker.title)", action: #selector(sendSticker(_:)), keyEquivalent: "")
                item.representedObject = sticker.identifier
                item.target = self
                stickerMenu.addItem(item)
            }
            stickerItem.submenu = stickerMenu
            menu.addItem(stickerItem)
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
            let layout = Self.bubbleLayout(for: bubbleText, in: bounds)
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: layout.bubbleRect, xRadius: 14, yRadius: 14).fill()
            (bubbleText as NSString).draw(
                with: layout.textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                attributes: Self.bubbleAttributes
            )
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
    @objc private func removeFriend() { onRemoveFriend?() }

    @objc private func changeScale(_ sender: NSMenuItem) {
        let scales = PetScale.allCases
        guard scales.indices.contains(sender.tag) else { return }
        onScaleChange?(scales[sender.tag])
    }

    @objc private func copyPetCode() { onCopyPetCode?() }
    @objc private func addFriend() { onAddFriend?() }
    @objc private func resetPetCode() { onResetPetCode?() }
    @objc private func reviewFriendRequest(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let request = pendingFriendRequests.first(where: { $0.id == id }) else { return }
        onReviewFriendRequest?(request)
    }

    @objc private func selectFriend(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let friend = friends.first(where: { $0.id == id }) else { return }
        onSelectFriend?(friend)
    }
    @objc private func editProfile() { onEditProfile?() }
    @objc private func sendMessage() { onSendMessage?() }
    @objc private func sendSticker(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let sticker = PetSticker(rawValue: id) else { return }
        onSendSticker?(sticker)
    }
    @objc private func openMessage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let message = recentMessages.first(where: { $0.id == id }) else { return }
        onOpenMessage?(message)
    }
    @objc private func markMessagesRead() { onMarkMessagesRead?() }

    private var confirmedFriend: PetPeer? {
        guard let pairedFriend,
              pairedFriend.name != "配对码已创建",
              pairedFriend.name != "正在加入配对" else { return nil }
        return pairedFriend
    }
}
