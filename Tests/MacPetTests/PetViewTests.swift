import AppKit
import XCTest
@testable import MacPet

@MainActor
final class PetViewTests: XCTestCase {
    func testSingleClickRunsOnlyLocalInteractionAfterDoubleClickWindow() async throws {
        let view = PetView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 250),
            singleClickDelay: 0.01
        )
        var localFrames: [String] = []
        var remoteActions: [PetEvent.Kind] = []
        view.onLocalInteraction = { localFrames.append($0) }
        view.onSendAction = { remoteActions.append($0) }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 1))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1))

        XCTAssertEqual(localFrames, [])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(localFrames.count, 1)
        XCTAssertEqual(remoteActions, [])
    }

    func testDoubleClickSendsOnePokeWithoutRunningLocalInteraction() throws {
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
        var localFrames: [String] = []
        var remoteActions: [PetEvent.Kind] = []
        view.onLocalInteraction = { localFrames.append($0) }
        view.onSendAction = { remoteActions.append($0) }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 1))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1))
        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 2))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 2))

        XCTAssertEqual(localFrames, [])
        XCTAssertEqual(remoteActions, [.poke])
    }

    func testDraggingPetDoesNotTriggerLocalOrRemoteInteraction() async throws {
        let view = PetView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 250),
            singleClickDelay: 0.01
        )
        var localFrames: [String] = []
        var remoteActions: [PetEvent.Kind] = []
        view.onLocalInteraction = { localFrames.append($0) }
        view.onSendAction = { remoteActions.append($0) }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: .zero, clickCount: 1))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 0), clickCount: 1))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 20, y: 0), clickCount: 1))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(localFrames, [])
        XCTAssertEqual(remoteActions, [])
    }

    func testDraggingOnSecondClickDoesNotSendPoke() throws {
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
        var remoteActions: [PetEvent.Kind] = []
        view.onSendAction = { remoteActions.append($0) }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: .zero, clickCount: 2))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 0), clickCount: 2))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 20, y: 0), clickCount: 2))

        XCTAssertEqual(remoteActions, [])
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint = .zero,
        clickCount: Int
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        ))
    }
}
