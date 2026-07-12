enum BuddyFrames {
    static let names = [
        "ai_buddy_00", "ai_buddy_03", "ai_buddy_04", "ai_buddy_05", "ai_buddy_06",
        "ai_buddy_07", "ai_buddy_08", "ai_buddy_09", "ai_buddy_10", "ai_buddy_11", "ai_buddy_12"
    ]

    static let initialIndex = 3

    static func nextIndex(after index: Int) -> Int {
        (index + 1) % names.count
    }
}
