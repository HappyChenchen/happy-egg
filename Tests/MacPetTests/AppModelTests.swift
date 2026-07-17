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

    func testDeviceAuthTokenPersistsAcrossModelInstances() {
        let suiteName = "MacPetTests.AuthToken.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        let second = AppModel(service: LocalPetInteractionService(), defaults: defaults)

        XCTAssertEqual(first.authToken.count, 64)
        XCTAssertNotNil(first.authToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
        XCTAssertEqual(first.authToken, second.authToken)
    }

    func testPetCodeAndIncomingFriendRequestUpdateModel() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let suiteName = "MacPetTests.PetCode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: service, defaults: defaults)
        let request = PetFriendRequest(
            id: String(repeating: "c", count: 32),
            senderPeerID: String(repeating: "a", count: 32),
            senderName: "Alice"
        )
        model.startListening()
        await Task.yield()

        await service.simulatePetCode("123456")
        await service.simulateFriendRequest(request)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.petCode, "123456")
        XCTAssertEqual(model.pendingFriendRequests, [request])
        XCTAssertEqual(model.bubbleText, "收到 Alice 的好友申请")
    }

    func testSendingFriendRequestValidatesAndUsesSixDigitPetCode() async {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service)

        await model.sendFriendRequest(code: "1234")
        XCTAssertEqual(model.bubbleText, "请输入 6 位宠物号")
        await model.sendFriendRequest(code: "654321")

        let requestedCodes = await service.requestedFriendCodeValues()
        XCTAssertEqual(requestedCodes, ["654321"])
        XCTAssertEqual(model.bubbleText, "好友申请已发送")
    }

    func testAcceptedFriendRequestSavesAndSelectsFriend() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let suiteName = "MacPetTests.AcceptFriend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: service, defaults: defaults)
        let requestID = String(repeating: "d", count: 32)
        let request = PetFriendRequest(
            id: requestID,
            senderPeerID: String(repeating: "b", count: 32),
            senderName: "Bob"
        )
        model.startListening()
        await Task.yield()
        await service.simulateFriendRequest(request)
        await service.simulateFriendRequestAccepted(
            requestID: requestID,
            peer: PetPeer(id: requestID, name: "Bob", peerID: request.senderPeerID)
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.pendingFriendRequests, [])
        XCTAssertEqual(model.pairedFriend?.peerID, request.senderPeerID)
        XCTAssertEqual(model.friends.first?.name, "Bob")
    }

    func testFriendProfileUpdateRenamesSavedFriend() async throws {
        let service = LocalPetInteractionService(responseDelay: .zero)
        let suiteName = "MacPetTests.FriendProfile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let peerID = String(repeating: "b", count: 32)
        let friend = PetPeer(id: "request", name: "Bob", peerID: peerID)
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let model = AppModel(service: service, defaults: defaults)
        model.startListening()
        await Task.yield()

        await service.simulateFriendProfile(peerID: peerID, name: "Bobby")
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.friends.first?.name, "Bobby")
        XCTAssertEqual(model.pairedFriend?.name, "Bobby")
        XCTAssertEqual(model.bubbleText, "Bob 改名为 Bobby")
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

    func testSelectedFriendPersistsAcrossModelInstances() async throws {
        let suiteName = "MacPetTests.SelectedFriend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let friends = [
            PetPeer(id: "room-a", name: "Alice", peerID: String(repeating: "a", count: 32)),
            PetPeer(id: "room-b", name: "Bob", peerID: String(repeating: "b", count: 32))
        ]
        defaults.set(try JSONEncoder().encode(friends), forKey: "com.macpet.friends")
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)

        await model.selectFriend(friends[1])
        let restored = AppModel(service: LocalPetInteractionService(), defaults: defaults)

        XCTAssertEqual(restored.pairedFriend, friends[1])
    }

    func testOnlySavedFriendIsSelectedAutomatically() throws {
        let suiteName = "MacPetTests.SingleFriendSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let friend = PetPeer(
            id: "room-a",
            name: "Alice",
            peerID: String(repeating: "a", count: 32)
        )
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")

        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)

        XCTAssertEqual(model.pairedFriend, friend)
    }

    func testNewlyPairedFriendBecomesPersistedSelection() async throws {
        let suiteName = "MacPetTests.NewPairSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let existingFriend = PetPeer(
            id: "room-a",
            name: "Alice",
            peerID: String(repeating: "a", count: 32)
        )
        defaults.set(try JSONEncoder().encode([existingFriend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero)
        let model = AppModel(service: service, defaults: defaults)
        model.startListening()
        await Task.yield()

        await model.joinPublicPairing(code: "2048")
        let newPeerID = String(repeating: "b", count: 32)
        await service.simulatePeerAvailable(name: "Bob", peerID: newPeerID)
        try await Task.sleep(for: .milliseconds(20))
        let restored = AppModel(service: LocalPetInteractionService(), defaults: defaults)

        XCTAssertEqual(restored.pairedFriend?.peerID, newPeerID)
        XCTAssertEqual(restored.pairedFriend?.name, "Bob")
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
        let suiteName = "MacPetTests.NoPairingInteraction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(service: LocalPetInteractionService(), defaults: defaults)
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
        let service = LocalPetInteractionService(responseDelay: .milliseconds(30))
        let model = AppModel(service: service, defaults: defaults)
        await model.selectFriend(friend)
        model.startListening()
        await Task.yield()
        await service.simulatePresenceSnapshot(onlinePeerIDs: [stableID])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.isFriendOnline(friend))

        model.removeFriend(friend)

        XCTAssertEqual(model.friends, [friend])
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(model.friends.isEmpty)
        XCTAssertNil(model.pairedFriend)
        XCTAssertFalse(model.isFriendOnline(friend))
        XCTAssertNil(defaults.string(forKey: "com.macpet.selected-friend-id"))
        let restored = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertTrue(restored.friends.isEmpty)
        let removedPeerIDs = await service.removedFriendPeerIDValues()
        XCTAssertEqual(removedPeerIDs, [stableID])
    }

    func testRemovingFriendKeepsLocalRecordWhenRelayDoesNotConfirm() async throws {
        let suiteName = "MacPetTests.RemoveFriendFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stableID = String(repeating: "d", count: 32)
        let friend = PetPeer(id: "room-d", name: "Dana", peerID: stableID)
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        let service = LocalPetInteractionService(responseDelay: .zero, sendSucceeds: false)
        let model = AppModel(service: service, defaults: defaults)

        model.removeFriend(friend)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.friends, [friend])
        XCTAssertEqual(model.bubbleText, "删除好友失败，请联网后重试")
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

    private func modelWithSavedFriend(
        _ friend: PetPeer,
        service: LocalPetInteractionService,
        suiteName: String
    ) throws -> (AppModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(try JSONEncoder().encode([friend]), forKey: "com.macpet.friends")
        return (AppModel(service: service, defaults: defaults), defaults)
    }

    func testSendingTextMessageWaitsForRelayAcceptanceBeforeShowingSuccess() async throws {
        let suiteName = "MacPetTests.SendMessage.\(UUID().uuidString)"
        let stableID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: stableID)
        let service = LocalPetInteractionService(
            responseDelay: .milliseconds(100),
            messageSendResult: .accepted
        )
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await model.selectFriend(friend)

        let pendingSend = Task { await model.sendMessage(kind: .text, body: "  在吗  ") }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNotEqual(model.bubbleText, "已给 Alice 留言")

        await pendingSend.value

        let sent = await service.sentMessageValues()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.peerID, stableID)
        XCTAssertEqual(sent.first?.kind, .text)
        XCTAssertEqual(sent.first?.body, "在吗")
        XCTAssertEqual(model.bubbleText, "已给 Alice 留言")
    }

    func testRateLimitedMessageShowsLocalizedRelayFailure() async throws {
        let suiteName = "MacPetTests.RateLimitedMessage.\(UUID().uuidString)"
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: String(repeating: "a", count: 32))
        let service = LocalPetInteractionService(
            responseDelay: .zero,
            messageSendResult: .rejected(message: "rate limit")
        )
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await model.selectFriend(friend)

        await model.sendMessage(kind: .text, body: "在吗")

        XCTAssertEqual(model.bubbleText, "留言太频繁，请稍后再试")
    }

    func testMessageTransportFailureShowsReconnectFailure() async throws {
        let suiteName = "MacPetTests.MessageTransportFailure.\(UUID().uuidString)"
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: String(repeating: "a", count: 32))
        let service = LocalPetInteractionService(
            responseDelay: .zero,
            messageSendResult: .transportFailure
        )
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await model.selectFriend(friend)

        await model.sendMessage(kind: .text, body: "在吗")

        XCTAssertEqual(model.bubbleText, "留言发送失败，正在重新连接")
    }

    func testSendingStickerUsesWhitelistedIdentifier() async throws {
        let suiteName = "MacPetTests.SendSticker.\(UUID().uuidString)"
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: String(repeating: "a", count: 32))
        let service = LocalPetInteractionService(responseDelay: .zero)
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await model.selectFriend(friend)

        await model.sendMessage(kind: .sticker, body: PetSticker.love.identifier)

        let sent = await service.sentMessageValues()
        XCTAssertEqual(sent.first?.kind, .sticker)
        XCTAssertEqual(sent.first?.body, "sticker_love")
        XCTAssertEqual(model.bubbleText, "已发给 Alice ❤️")
    }

    func testEmptyTextMessageIsRejectedBeforeSending() async throws {
        let suiteName = "MacPetTests.EmptyMessage.\(UUID().uuidString)"
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: String(repeating: "a", count: 32))
        let service = LocalPetInteractionService(responseDelay: .zero)
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await model.selectFriend(friend)

        await model.sendMessage(kind: .text, body: "   ")

        XCTAssertEqual(model.bubbleText, "留言不能为空")
        let sent = await service.sentMessageValues()
        XCTAssertTrue(sent.isEmpty)
    }

    func testNormalizedTextLimitsEmojiByUnicodeScalarCount() {
        let input = String(repeating: "😀", count: 301)

        let normalized = PetMessage.normalizedText(input)

        XCTAssertEqual(normalized.unicodeScalars.count, PetMessage.maxTextLength)
        XCTAssertEqual(normalized, String(repeating: "😀", count: 300))
    }

    func testSendingMessageWithoutFriendShowsHint() async {
        let model = AppModel(service: LocalPetInteractionService(responseDelay: .zero))
        await model.sendMessage(kind: .text, body: "hi")
        XCTAssertEqual(model.bubbleText, "请选择好友后再留言")
    }

    func testIncomingMessageIsStoredUnreadResolvedAndAcknowledged() async throws {
        let suiteName = "MacPetTests.IncomingMessage.\(UUID().uuidString)"
        let senderID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: senderID)
        let service = LocalPetInteractionService(responseDelay: .zero)
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.startListening()
        await Task.yield()
        let message = PetMessage(
            id: String(repeating: "e", count: 32),
            senderPeerID: senderID,
            senderName: "线上名字",
            kind: .text,
            body: "晚上一起玩",
            receivedAt: .now
        )

        await service.simulateFriendMessage(message)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages.first?.body, "晚上一起玩")
        XCTAssertEqual(model.messages.first?.senderName, "Alice")
        XCTAssertEqual(model.unreadMessageCount, 1)
        XCTAssertEqual(model.bubbleText, "Alice：晚上一起玩")
        let acked = await service.acknowledgedMessageValues()
        XCTAssertEqual(acked, [String(repeating: "e", count: 32)])
    }

    func testDuplicateIncomingMessageIsAcknowledgedWithoutDuplicateStorage() async throws {
        let suiteName = "MacPetTests.DuplicateMessage.\(UUID().uuidString)"
        let senderID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: senderID)
        let service = LocalPetInteractionService(responseDelay: .zero)
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.startListening()
        await Task.yield()
        let message = PetMessage(
            id: String(repeating: "e", count: 32),
            senderPeerID: senderID,
            senderName: "Alice",
            kind: .sticker,
            body: PetSticker.party.identifier
        )

        await service.simulateFriendMessage(message)
        await service.simulateFriendMessage(message)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.messages.count, 1)
        let acked = await service.acknowledgedMessageValues()
        XCTAssertEqual(acked.count, 2)
    }

    func testStoredMessagePersistsAndOpeningMarksItRead() async throws {
        let suiteName = "MacPetTests.PersistMessage.\(UUID().uuidString)"
        let senderID = String(repeating: "a", count: 32)
        let friend = PetPeer(id: "room-a", name: "Alice", peerID: senderID)
        let service = LocalPetInteractionService(responseDelay: .zero)
        let (model, defaults) = try modelWithSavedFriend(friend, service: service, suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.startListening()
        await Task.yield()
        await service.simulateFriendMessage(PetMessage(
            id: String(repeating: "e", count: 32),
            senderPeerID: senderID,
            senderName: "Alice",
            kind: .text,
            body: "记得回我"
        ))
        try await Task.sleep(for: .milliseconds(20))

        let restored = AppModel(service: LocalPetInteractionService(), defaults: defaults)
        XCTAssertEqual(restored.messages.count, 1)
        XCTAssertEqual(restored.unreadMessageCount, 1)

        restored.openMessage(restored.messages[0])
        XCTAssertEqual(restored.unreadMessageCount, 0)
        XCTAssertEqual(restored.bubbleText, "Alice：记得回我")
    }

}
