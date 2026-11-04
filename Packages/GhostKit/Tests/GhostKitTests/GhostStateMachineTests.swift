import XCTest
@testable import GhostKit

/// Tests des règles pures de transition.
final class GhostStateMachineTests: XCTestCase {

    func testAllowedTransitions() {
        XCTAssertTrue(GhostStateMachine.canTransition(from: .stopped, to: .active))
        XCTAssertTrue(GhostStateMachine.canTransition(from: .active, to: .paused))
        XCTAssertTrue(GhostStateMachine.canTransition(from: .paused, to: .active))
        XCTAssertTrue(GhostStateMachine.canTransition(from: .active, to: .stopped))
        XCTAssertTrue(GhostStateMachine.canTransition(from: .paused, to: .stopped))
    }

    func testForbiddenTransitions() {
        XCTAssertFalse(GhostStateMachine.canTransition(from: .stopped, to: .paused))
        for state in GhostState.allCases {
            XCTAssertFalse(GhostStateMachine.canTransition(from: state, to: state),
                           "\(state) → \(state) ne doit pas être autorisé")
        }
    }

    func testExactlyFiveTransitionsAreAllowed() {
        let allowed = GhostState.allCases.flatMap { from in
            GhostState.allCases.filter { GhostStateMachine.canTransition(from: from, to: $0) }
        }
        XCTAssertEqual(allowed.count, 5)
    }

    func testToggledState() {
        XCTAssertEqual(GhostStateMachine.toggledState(from: .active), .paused)
        XCTAssertEqual(GhostStateMachine.toggledState(from: .paused), .active)
        XCTAssertNil(GhostStateMachine.toggledState(from: .stopped))
    }

    func testDisplayNames() {
        XCTAssertEqual(GhostState.active.displayName, "ACTIVE")
        XCTAssertEqual(GhostState.paused.displayName, "PAUSED")
        XCTAssertEqual(GhostState.stopped.displayName, "STOPPED")
    }
}
