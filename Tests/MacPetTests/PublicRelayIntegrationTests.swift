import XCTest
@testable import MacPet

@MainActor
final class PublicRelayIntegrationTests: XCTestCase {
    func testPresenceAndAcknowledgedDeliveryAgainstProductionRelay() async throws {
        guard ProcessInfo.processInfo.environment["MACPET_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set MACPET_INTEGRATION_TESTS=1 to exercise the production relay")
        }

        let alice = PublicPetInteractionService()
        let bob = PublicPetInteractionService()
        let aliceID = Self.makeProfileID()
        let bobID = Self.makeProfileID()
        let aliceUpdates = await alice.connectionUpdates()
        let bobEvents = await bob.incomingEvents()
        let bobOnline = expectation(description: "Alice sees Bob online")
        let bobReceivedEvent = expectation(description: "Bob receives Alice's interaction")
        var receivedEvent: PetEvent?

        let presenceListener = Task { @MainActor in
            for await update in aliceUpdates {
                if case let .friendPresence(peerID, isOnline) = update,
                   peerID == bobID,
                   isOnline {
                    bobOnline.fulfill()
                    return
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
            presenceListener.cancel()
            eventListener.cancel()
        }

        await alice.updatePresence(peerID: aliceID, name: "集成测试A", friendPeerIDs: [bobID])
        await bob.updatePresence(peerID: bobID, name: "集成测试B", friendPeerIDs: [aliceID])
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
}
