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

    func testDirectoryReturnsNamedPeer() async {
        let service = LocalPetInteractionService()
        let alice = PetPeer(id: "alice-device", name: "Alice")
        await service.setPeers([alice])
        let peers = await service.availablePeers()
        XCTAssertEqual(peers, [alice])
    }

    func testPairingStoresFriendName() {
        let model = AppModel(service: LocalPetInteractionService())
        model.pair(with: PetPeer(id: "alice-device", name: "Alice"))
        XCTAssertEqual(model.pairedFriend?.name, "Alice")
    }

    func testInteractionWithoutPairingStillShowsLocalEffect() async {
        let model = AppModel(service: LocalPetInteractionService())
        await model.sendInteraction(kind: .poke, frameName: "ai_buddy_07")
        XCTAssertEqual(model.bubbleText, "本地互动成功，配对后可拍朋友")
        XCTAssertEqual(model.emotion, .happy)
        XCTAssertEqual(model.activeFrameName, "ai_buddy_07")
    }

    func testPokeTargetsPairedFriendAndSynchronizesFrame() async {
        let service = LocalPetInteractionService(responseDelay: .seconds(10))
        let model = AppModel(service: service)
        model.pair(with: PetPeer(id: "alice-device", name: "Alice"))
        let task = Task { await model.sendInteraction(kind: .poke, frameName: "ai_buddy_07") }
        await Task.yield()
        XCTAssertEqual(model.bubbleText, "已拍一拍 Alice")
        XCTAssertEqual(model.emotion, .happy)
        XCTAssertEqual(model.activeFrameName, "ai_buddy_07")
        task.cancel()
    }

    func testPetSizeChangesToChosenScale() {
        let suiteName = "MacPetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        model.setPetScale(.large)
        XCTAssertEqual(model.petScale, .large)
        XCTAssertEqual(defaults.double(forKey: "com.macpet.pet-scale"), 1.3, accuracy: 0.001)
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

    func testPeerRenameUpdatesFriendNameAndShowsNotice() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service)
        model.pair(with: PetPeer(id: "alice-device", name: "Alice"))
        model.startListening()
        await Task.yield()
        await service.simulatePeerRenamed(to: "阿梨")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.pairedFriend?.name, "阿梨")
        XCTAssertEqual(model.bubbleText, "Alice 改名为 阿梨")
    }

    func testProfileChangeBroadcastsWhenAlreadyPaired() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let suiteName = "MacPetTests.Profile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: service, defaults: defaults)
        model.pair(with: PetPeer(id: "alice-device", name: "Alice"))
        model.setProfile(owner: " 我 ", pet: " 小蛋 ")
        try await Task.sleep(for: .milliseconds(20))
        let updatedNames = await service.updatedNameValues()
        XCTAssertEqual(model.ownerName, "我")
        XCTAssertEqual(model.petName, "小蛋")
        XCTAssertEqual(updatedNames, ["小蛋"])
        XCTAssertEqual(model.bubbleText, "名字已更新，朋友会看到")
    }
}
