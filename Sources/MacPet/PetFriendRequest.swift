import Foundation

struct PetFriendRequest: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let senderPeerID: String
    let senderName: String
}
