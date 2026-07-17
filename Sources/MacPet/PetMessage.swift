import Foundation

/// A short text note or preset sticker left for a friend. Messages persist on the
/// relay while the recipient is offline and are delivered on their next connection.
struct PetMessage: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case sticker
    }

    let id: String
    let senderPeerID: String
    let senderName: String
    let kind: Kind
    let body: String
    let receivedAt: Date
    var isRead: Bool

    init(
        id: String,
        senderPeerID: String,
        senderName: String,
        kind: Kind,
        body: String,
        receivedAt: Date = .now,
        isRead: Bool = false
    ) {
        self.id = id
        self.senderPeerID = senderPeerID
        self.senderName = senderName
        self.kind = kind
        self.body = body
        self.receivedAt = receivedAt
        self.isRead = isRead
    }

    /// Maximum Unicode scalar count accepted by the relay; clients mirror this boundary.
    static let maxTextLength = 300

    static func normalizedText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.unicodeScalars.prefix(maxTextLength))
    }

    /// One-line preview used in the friend message list.
    var preview: String {
        switch kind {
        case .text:
            return body
        case .sticker:
            return PetSticker(rawValue: body).map { "\($0.glyph) \($0.title)" } ?? "贴纸"
        }
    }

    /// Bubble text shown when a message arrives or is opened.
    func bubbleText() -> String {
        switch kind {
        case .text:
            return "\(senderName)：\(body)"
        case .sticker:
            let glyph = PetSticker(rawValue: body)?.glyph ?? "🎁"
            return "\(senderName) 发来 \(glyph)"
        }
    }
}

/// Preset stickers whose identifiers are whitelisted by the relay. The client and
/// web companion own the glyph and label; the relay only validates the identifier.
enum PetSticker: String, CaseIterable, Sendable {
    case wave = "sticker_wave"
    case love = "sticker_love"
    case laugh = "sticker_laugh"
    case cry = "sticker_cry"
    case thumbsup = "sticker_thumbsup"
    case party = "sticker_party"
    case gift = "sticker_gift"
    case coffee = "sticker_coffee"
    case moon = "sticker_moon"
    case flower = "sticker_flower"

    /// The relay-whitelisted identifier sent over the wire (identical to `rawValue`).
    var identifier: String { rawValue }

    var glyph: String {
        switch self {
        case .wave: "👋"
        case .love: "❤️"
        case .laugh: "😂"
        case .cry: "😭"
        case .thumbsup: "👍"
        case .party: "🎉"
        case .gift: "🎁"
        case .coffee: "☕"
        case .moon: "🌙"
        case .flower: "🌸"
        }
    }

    var title: String {
        switch self {
        case .wave: "挥手"
        case .love: "爱心"
        case .laugh: "大笑"
        case .cry: "大哭"
        case .thumbsup: "点赞"
        case .party: "撒花"
        case .gift: "礼物"
        case .coffee: "喝杯"
        case .moon: "晚安"
        case .flower: "送花"
        }
    }
}
