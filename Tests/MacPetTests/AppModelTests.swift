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

    func testStableProfileIDPersistsAcrossModelInstances() {
        let suiteName = "MacPetTests.ProfileID.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        let second = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertEqual(first.peerID.count, 32)
        XCTAssertEqual(first.peerID, first.peerID.lowercased())
        XCTAssertEqual(first.peerID, second.peerID)
    }

    func testInstanceLaunchArgumentsUseSeparateDefaultsSuites() {
        let instanceA = "test-a-\(UUID().uuidString.prefix(8))"
        let instanceB = "test-b-\(UUID().uuidString.prefix(8))"
        let defaultsA = AppModel.launchDefaults(arguments: ["MacPet", "--instance", instanceA])
        let defaultsB = AppModel.launchDefaults(arguments: ["MacPet", "--instance", instanceB])
        defer {
            defaultsA.removePersistentDomain(forName: "com.macpet.prototype.instance.\(instanceA.lowercased())")
            defaultsB.removePersistentDomain(forName: "com.macpet.prototype.instance.\(instanceB.lowercased())")
        }

        defaultsA.set("小A", forKey: "com.macpet.pet-name")
        defaultsB.set("小B", forKey: "com.macpet.pet-name")
        let modelA = AppModel(service: LocalPetInteractionService(), defaults: defaultsA)
        let modelB = AppModel(service: LocalPetInteractionService(), defaults: defaultsB)
        XCTAssertNotEqual(modelA.peerID, modelB.peerID)
        XCTAssertNotEqual(modelA.petName, modelB.petName)
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

    func testCreatedPairingCodeIsShortAndRelayCompatible() async {
        let model = AppModel(service: LocalPetInteractionService())
        let code = await model.createPublicPairing()
        XCTAssertEqual(code.count, 8)
        XCTAssertEqual(code, code.lowercased())
        XCTAssertNotNil(code.range(of: "^[a-hj-km-np-z2-9]{8}$", options: .regularExpression))
    }

    func testInteractionWhilePairingWaitsForFriend() async {
        let model = AppModel(service: LocalPetInteractionService(responseDelay: .zero))
        _ = await model.createPublicPairing()
        await model.sendInteraction(kind: .poke)
        XCTAssertEqual(model.bubbleText, "本地互动成功，配对后可拍朋友")
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

    func testPeerUnavailableKeepsFriendAndShowsReconnectNotice() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service)
        model.pair(with: PetPeer(id: "alice-device", name: "Alice"))
        model.startListening()
        await Task.yield()
        await service.simulatePeerUnavailable()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.pairedFriend?.name, "Alice")
        XCTAssertEqual(model.bubbleText, "朋友已离线，等待重连")
    }

    func testSameNamedFriendKeepsOnlyNewestPairing() async throws {
        let suiteName = "MacPetTests.Friends.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        model.pair(with: PetPeer(id: "old-room", name: "陈开心"))
        model.startListening()
        await Task.yield()
        await service.simulatePeerAvailable(name: "陈开心")
        try await Task.sleep(for: .milliseconds(20))
        model.pair(with: PetPeer(id: "new-room", name: "陈开心"))
        await service.simulatePeerAvailable(name: "陈开心")
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.friends, [PetPeer(id: "new-room", name: "陈开心")])
        let restored = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertEqual(restored.friends, [PetPeer(id: "new-room", name: "陈开心")])
    }

    func testStableIDsAllowDifferentFriendsToShareAName() throws {
        let suiteName = "MacPetTests.FriendsStable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let friends = [
            PetPeer(id: "room-a", name: "小白", peerID: String(repeating: "a", count: 32)),
            PetPeer(id: "room-b", name: "小白", peerID: String(repeating: "b", count: 32))
        ]
        defaults.set(try JSONEncoder().encode(friends), forKey: "com.macpet.friends")
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertEqual(model.friends, friends)
    }

    func testSelfPeerIsNotSavedAsFriend() async throws {
        let suiteName = "MacPetTests.SelfPairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("我的宠物", forKey: "com.macpet.pet-name")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        model.pair(with: PetPeer(id: "same-room", name: "正在加入配对"))
        model.startListening()
        await Task.yield()
        await service.simulatePeerAvailable(name: "我的宠物", peerID: model.peerID)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(model.confirmedFriend)
        XCTAssertNil(model.pairedFriend)
        XCTAssertTrue(model.friends.isEmpty)
        XCTAssertEqual(model.bubbleText, "不能和自己的宠物配对")
    }

    func testLegacySelfNamedFriendIsRemovedOnLoad() throws {
        let suiteName = "MacPetTests.SelfFriendMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("萌萌", forKey: "com.macpet.pet-name")
        let saved = [
            PetPeer(id: "self-room", name: "我的宠物"),
            PetPeer(id: "friend-room", name: "朋友")
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: "com.macpet.friends")
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)

        XCTAssertEqual(model.friends, [PetPeer(id: "friend-room", name: "朋友")])
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
