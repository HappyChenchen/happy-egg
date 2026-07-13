import CoreGraphics

struct PetPeer: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

enum PetScale: CGFloat, CaseIterable, Sendable {
    case small = 0.8
    case normal = 1.0
    case large = 1.3
    case extraLarge = 1.6

    var title: String {
        switch self {
        case .small: "小 (80%)"
        case .normal: "正常 (100%)"
        case .large: "大 (130%)"
        case .extraLarge: "超大 (160%)"
        }
    }
}
