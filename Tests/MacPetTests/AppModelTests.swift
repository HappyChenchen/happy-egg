import XCTest
@testable import MacPet

@MainActor
final class AppModelTests: XCTestCase {
    func testBuddyFramesCycleBackToFirstFrame() {
        var index = BuddyFrames.initialIndex
        for _ in 0..<BuddyFrames.names.count {
            index = BuddyFrames.nextIndex(after: index)
        }
        XCTAssertEqual(index, BuddyFrames.initialIndex)
    }

    func testModelStartsInIdleState() {
        let model = AppModel(service: LocalPetInteractionService())
        XCTAssertEqual(model.emotion, .idle)
    }

    func testPokeImmediatelyShowsOutgoingMessageAndFrame() async {
        let model = AppModel(service: LocalPetInteractionService(responseDelay: .seconds(10)))
        let task = Task { await model.sendInteraction(kind: .poke, frameName: "ai_buddy_07") }
        await Task.yield()
        XCTAssertEqual(model.bubbleText, "已拍一拍朋友")
        XCTAssertEqual(model.emotion, .happy)
        XCTAssertEqual(model.activeFrameName, "ai_buddy_07")
        task.cancel()
    }

    func testIncomingPokeShowsFriendMessage() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service)
        model.startListening()
        await Task.yield()
        await service.simulateIncomingPoke(from: "阿梨")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.bubbleText, "阿梨拍了拍你")
        XCTAssertEqual(model.emotion, .happy)
        XCTAssertEqual(model.activeFrameName, "ai_buddy_00")
    }
}
