import XCTest
@testable import MacPet

@MainActor
final class PublicRelayIntegrationTests: XCTestCase {
    func testPermanentFriendRequestAndAcknowledgedDeliveryAgainstProductionRelay() async throws {
        guard ProcessInfo.processInfo.environment["MACPET_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set MACPET_INTEGRATION_TESTS=1 to exercise the production relay")
        }

        let alice = PublicPetInteractionService()
        let bob = PublicPetInteractionService()
        let aliceID = Self.makeProfileID()
        let bobID = Self.makeProfileID()
        let aliceToken = Self.makeAuthToken()
        let bobToken = Self.makeAuthToken()
        let aliceUpdates = await alice.connectionUpdates()
        let bobUpdates = await bob.connectionUpdates()
        let bobEvents = await bob.incomingEvents()
        let bobCodeReceived = expectation(description: "Bob receives a permanent pet code")
        let bobRequestReceived = expectation(description: "Bob receives Alice's friend request")
        let aliceAccepted = expectation(description: "Alice receives accepted friend result")
        let bobAccepted = expectation(description: "Bob receives accepted friend result")
        let bobOnline = expectation(description: "Alice sees Bob online")
        let bobReceivedEvent = expectation(description: "Bob receives Alice's interaction")
        var bobCode: String?
        var incomingRequest: PetFriendRequest?
        var acceptedRequestID: String?
        var receivedEvent: PetEvent?

        let aliceListener = Task { @MainActor in
            for await update in aliceUpdates {
                if case let .friendRequestAccepted(requestID, peer) = update, peer.peerID == bobID {
                    acceptedRequestID = requestID
                    aliceAccepted.fulfill()
                } else if case let .friendPresence(peerID, isOnline) = update, peerID == bobID, isOnline {
                    bobOnline.fulfill()
                }
            }
        }
        let bobListener = Task { @MainActor in
            for await update in bobUpdates {
                switch update {
                case let .petCode(code):
                    guard bobCode == nil else { continue }
                    bobCode = code
                    bobCodeReceived.fulfill()
                case let .friendRequest(request):
                    incomingRequest = request
                    bobRequestReceived.fulfill()
                case let .friendRequestAccepted(requestID, peer) where peer.peerID == aliceID:
                    acceptedRequestID = requestID
                    bobAccepted.fulfill()
                default:
                    continue
                }
            }
        }
        let eventListener = Task { @MainActor in
            for await event in bobEvents {
                receivedEvent = event
                bobReceivedEvent.fulfill()
                return
            }
        }
        defer {
            aliceListener.cancel()
            bobListener.cancel()
            eventListener.cancel()
        }

        await alice.updatePresence(
            peerID: aliceID, authToken: aliceToken, name: "集成测试A", friendPeerIDs: []
        )
        await bob.updatePresence(
            peerID: bobID, authToken: bobToken, name: "集成测试B", friendPeerIDs: []
        )
        await fulfillment(of: [bobCodeReceived], timeout: 8)
        let requestSent = await alice.requestFriend(code: try XCTUnwrap(bobCode))
        XCTAssertTrue(requestSent)
        await fulfillment(of: [bobRequestReceived], timeout: 8)
        let responseSent = await bob.respondToFriendRequest(id: try XCTUnwrap(incomingRequest?.id), accept: true)
        XCTAssertTrue(responseSent)
        await fulfillment(of: [aliceAccepted, bobAccepted], timeout: 8)
        await alice.acknowledgeFriendRequest(id: try XCTUnwrap(acceptedRequestID))
        await bob.acknowledgeFriendRequest(id: try XCTUnwrap(acceptedRequestID))
        await alice.updatePresence(peerID: aliceID, authToken: aliceToken, name: "集成测试A", friendPeerIDs: [bobID])
        await bob.updatePresence(peerID: bobID, authToken: bobToken, name: "集成测试B", friendPeerIDs: [aliceID])
        await fulfillment(of: [bobOnline], timeout: 8)
        if ProcessInfo.processInfo.environment["MACPET_HEARTBEAT_TESTS"] == "1" {
            try await Task.sleep(for: .seconds(22))
        }

        let delivered = await alice.send(
            PetEvent(kind: .poke, senderName: "集成测试A", frameName: "ai_buddy_07"),
            to: bobID
        )

        XCTAssertTrue(delivered)
        await fulfillment(of: [bobReceivedEvent], timeout: 8)
        XCTAssertEqual(receivedEvent?.kind, .poke)
        XCTAssertEqual(receivedEvent?.senderName, "集成测试A")
        XCTAssertEqual(receivedEvent?.frameName, "ai_buddy_07")
    }

    private static func makeProfileID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func makeAuthToken() -> String {
        makeProfileID() + makeProfileID()
    }
}
