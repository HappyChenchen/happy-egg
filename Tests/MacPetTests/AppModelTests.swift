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

    func testNewProfileUsesFriendlyDefaultPetName() {
        let suiteName = "MacPetTests.DefaultPetName.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertEqual(model.petName, "陈团团")
    }

    func testLocalInstanceBUsesNumberedDefaultPetName() {
        let suiteName = "MacPetTests.InstanceBDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults, instanceID: "b")
        XCTAssertEqual(model.petName, "团团2")
    }

    func testLegacyPlaceholderPetNameMigratesToDefault() {
        let suiteName = "MacPetTests.DefaultPetNameMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("我的宠物", forKey: "com.macpet.pet-name")
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertEqual(model.petName, "陈团团")
        XCTAssertEqual(defaults.string(forKey: "com.macpet.pet-name"), "陈团团")
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
            defaultsA.removePersistentDomain(forName: "io.happypuppy.macpet.instance.\(instanceA.lowercased())")
            defaultsB.removePersistentDomain(forName: "io.happypuppy.macpet.instance.\(instanceB.lowercased())")
        }

        defaultsA.set("小A", forKey: "com.macpet.pet-name")
        defaultsB.set("小B", forKey: "com.macpet.pet-name")
        let modelA = AppModel(service: LocalPetInteractionService(), defaults: defaultsA)
        let modelB = AppModel(service: LocalPetInteractionService(), defaults: defaultsB)
        XCTAssertNotEqual(modelA.peerID, modelB.peerID)
        XCTAssertNotEqual(modelA.petName, modelB.petName)
    }

    func testLegacyInstanceDefaultsMigrateToProductionSuite() {
        let instanceID = "migration-\(UUID().uuidString.prefix(8))".lowercased()
        let legacySuiteName = "com.macpet.prototype.instance.\(instanceID)"
        let productionSuiteName = "io.happypuppy.macpet.instance.\(instanceID)"
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        let productionDefaults = UserDefaults(suiteName: productionSuiteName)!
        defer {
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
            productionDefaults.removePersistentDomain(forName: productionSuiteName)
        }
        legacyDefaults.set("旧名字", forKey: "com.macpet.pet-name")

        let migrated = AppModel.launchDefaults(arguments: ["MacPet", "--instance", instanceID])

        XCTAssertEqual(migrated.string(forKey: "com.macpet.pet-name"), "旧名字")
    }

    func testInstanceLaunchArgumentIsNormalized() {
        XCTAssertEqual(AppModel.launchInstanceID(arguments: ["MacPet", "--instance", "A"]), "a")
        XCTAssertNil(AppModel.launchInstanceID(arguments: ["MacPet", "--instance", "bad id"]))
    }

    func testSelectingFriendStoresFriendName() async {
        let model = AppModel(service: LocalPetInteractionService())
        await model.selectFriend(PetPeer(id: "alice-device", name: "Alice"))
        XCTAssertEqual(model.pairedFriend?.name, "Alice")
    }

    func testCreatedPairingCodeIsShortAndRelayCompatible() async {
        let model = AppModel(service: LocalPetInteractionService())
        let code = await model.createPublicPairing()
        XCTAssertEqual(code.count, 4)
        XCTAssertNotNil(code.range(of: "^[0-9]{4}$", options: .regularExpression))
        XCTAssertEqual(model.activePairingCode, code)
    }

    func testFailedOnlineInteractionDoesNotClaimDelivery() async throws {
        let stableID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "legacy-room", name: "Alice", peerID: stableID)
        let suiteName = "MacPetTests.FailedDelivery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero, sendSucceeds: false)
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(friend)
        model.startListening()
        await Task.yield()
        await service.simulatePresenceSnapshot(onlinePeerIDs: [stableID])
        try await Task.sleep(for: .milliseconds(20))

        await model.sendInteraction(kind: .poke)

        let sentTargets = await service.sentTargetValues()
        XCTAssertEqual(model.bubbleText, "发送失败，正在重新连接")
        XCTAssertFalse(model.isFriendOnline(friend))
        XCTAssertEqual(sentTargets, [stableID])
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

    func testLocalInteractionNeverSendsToOnlineFriend() async throws {
        let stableID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "alice-room", name: "Alice", peerID: stableID)
        let suiteName = "MacPetTests.LocalInteraction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(friend)
        model.startListening()
        await Task.yield()
        await service.simulatePresenceSnapshot(onlinePeerIDs: [stableID])
        try await Task.sleep(for: .milliseconds(20))

        model.interactLocally(frameName: "ai_buddy_07")

        XCTAssertEqual(model.bubbleText, "陈团团开心地回应你")
        XCTAssertEqual(model.emotion, .happy)
        XCTAssertEqual(model.activeFrameName, "ai_buddy_07")
        let sentTargets = await service.sentTargetValues()
        XCTAssertEqual(sentTargets, [])
    }

    func testPokeTargetsPairedFriendStableIDAndSynchronizesFrame() async throws {
        let suiteName = "MacPetTests.OnlineInteraction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stableID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "alice-room", name: "Alice", peerID: stableID)
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(friend)
        model.startListening()
        await Task.yield()
        await service.simulatePresenceSnapshot(onlinePeerIDs: [stableID])
        try await Task.sleep(for: .milliseconds(20))
        await model.sendInteraction(kind: .poke, frameName: "ai_buddy_07")
        XCTAssertEqual(model.bubbleText, "已拍一拍 Alice")
        XCTAssertEqual(model.emotion, .happy)
        XCTAssertEqual(model.activeFrameName, "ai_buddy_07")
        let sentTargets = await service.sentTargetValues()
        XCTAssertEqual(sentTargets, [stableID])
    }

    func testOfflineFriendCannotReceiveInteraction() async throws {
        let suiteName = "MacPetTests.OfflineInteraction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stableID = String(repeating: "c", count: 32)
        let friend = PetPeer(id: "cara-room", name: "Cara", peerID: stableID)
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(friend)

        await model.sendInteraction(kind: .poke)

        XCTAssertEqual(model.bubbleText, "Cara 不在线，未发送")
        let sentTargets = await service.sentTargetValues()
        XCTAssertEqual(sentTargets, [])
    }

    func testSelectingSavedFriendUsesPresenceInsteadOfRejoiningExpiredPairingRoom() async {
        let stableID = String(repeating: "d", count: 32)
        let friend = PetPeer(id: "old-pairing-code", name: "Dora", peerID: stableID)
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service)

        await model.selectFriend(friend)

        XCTAssertEqual(model.pairedFriend, friend)
        XCTAssertEqual(model.bubbleText, "Dora 当前不在线")
        let pairedRooms = await service.pairedRoomValues()
        XCTAssertTrue(pairedRooms.isEmpty)
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
        await model.selectFriend(PetPeer(id: "alice-device", name: "Alice"))
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
        await model.selectFriend(PetPeer(id: "alice-device", name: "Alice"))
        model.startListening()
        await Task.yield()
        await service.simulatePeerUnavailable()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.pairedFriend?.name, "Alice")
        XCTAssertEqual(model.bubbleText, "朋友已离线，等待重连")
    }

    func testPresenceSubscriptionContainsOnlySavedStableFriendIDs() async throws {
        let suiteName = "MacPetTests.PresenceSubscription.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stableID = String(repeating: "a", count: 32)
        let savedFriends = [
            PetPeer(id: "room-a", name: "Alice", peerID: stableID),
            PetPeer(id: "legacy-room", name: "旧好友")
        ]
        defaults.set(try JSONEncoder().encode(savedFriends), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)

        model.startListening()
        try await Task.sleep(for: .milliseconds(20))

        let subscriptions = await service.presenceSubscriptionValues()
        XCTAssertEqual(subscriptions.last, [stableID])
    }

    func testFriendPresenceSnapshotAndUpdatesChangeOnlineState() async throws {
        let suiteName = "MacPetTests.PresenceState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stableID = String(repeating: "b", count: 32)
        let friend = PetPeer(id: "room-b", name: "Bob", peerID: stableID)
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        model.startListening()
        await Task.yield()

        await service.simulatePresenceSnapshot(onlinePeerIDs: [stableID])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.isFriendOnline(friend))

        await service.simulateFriendPresence(peerID: stableID, isOnline: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(model.isFriendOnline(friend))
    }

    func testRemovingFriendClearsPairingPresenceAndPersistedRecord() async throws {
        let suiteName = "MacPetTests.RemoveFriend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stableID = String(repeating: "c", count: 32)
        let friend = PetPeer(id: "room-c", name: "Cara", peerID: stableID)
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(friend)
        model.startListening()
        await Task.yield()
        await service.simulatePresenceSnapshot(onlinePeerIDs: [stableID])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.isFriendOnline(friend))

        model.removeFriend(friend)

        XCTAssertTrue(model.friends.isEmpty)
        XCTAssertNil(model.pairedFriend)
        XCTAssertFalse(model.isFriendOnline(friend))
        let restored = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertTrue(restored.friends.isEmpty)
    }

    func testSameNamedFriendKeepsOnlyNewestPairing() async throws {
        let suiteName = "MacPetTests.Friends.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(PetPeer(id: "old-room", name: "陈开心"))
        model.startListening()
        await Task.yield()
        await service.simulatePeerAvailable(name: "陈开心")
        try await Task.sleep(for: .milliseconds(20))
        await model.selectFriend(PetPeer(id: "new-room", name: "陈开心"))
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
        await model.joinPublicPairing(code: "abcd2345")
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

    func testPetNameChangeBroadcastsWhenAlreadyPaired() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let suiteName = "MacPetTests.Profile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(PetPeer(id: "alice-device", name: "Alice"))
        model.setPetName(" 小蛋 ")
        try await Task.sleep(for: .milliseconds(20))
        let updatedNames = await service.updatedNameValues()
        XCTAssertEqual(model.petName, "小蛋")
        XCTAssertEqual(updatedNames, ["小蛋"])
        XCTAssertEqual(model.bubbleText, "名字已更新，朋友会看到")
    }
}
