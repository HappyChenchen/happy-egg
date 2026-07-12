import Foundation

struct PetEvent: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case poke
        case heart
        case celebrate

        var defaultFrameName: String {
            switch self {
            case .poke: "ai_buddy_00"
            case .heart: "ai_buddy_08"
            case .celebrate: "ai_buddy_04"
            }
        }

        var outgoingText: String {
            switch self {
            case .poke: "已拍一拍朋友"
            case .heart: "已送出爱心"
            case .celebrate: "已发起庆祝"
            }
        }

        var incomingText: String {
            switch self {
            case .poke: "拍了拍你"
            case .heart: "送了你一颗爱心"
            case .celebrate: "邀请你一起庆祝"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let senderName: String
    let frameName: String
    let sentAt: Date

    init(kind: Kind = .poke, senderName: String, frameName: String? = nil, sentAt: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.senderName = senderName
        self.frameName = frameName ?? kind.defaultFrameName
        self.sentAt = sentAt
    }
}
