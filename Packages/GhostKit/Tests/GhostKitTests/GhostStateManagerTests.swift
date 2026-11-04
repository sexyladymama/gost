import XCTest
@testable import GhostKit

/// Moteur espion : enregistre les appels reçus, sans aucune autre logique.
@MainActor
private final class SpyCore: GhostCoreInterface {
    enum Call: Equatable { case start, pause, resume, stop }
    let name = "Spy"
    private(set) var calls: [Call] = []
    func start() { calls.append(.start) }
    func pause() { calls.append(.pause) }
    func resume() { calls.append(.resume) }
    func stop() { calls.append(.stop) }
}

/// Tests du gestionnaire d'état et de sa communication avec le moteur.
///
/// Chaque test est `@MainActor ... async` : c'est la forme portable
/// (macOS et Linux) pour tester un type isolé sur le thread principal.
final class GhostStateManagerTests: XCTestCase {

    /// Crée un gestionnaire neuf relié à un moteur espion.
    @MainActor
    private func makeSUT() -> (GhostStateManager, SpyCore) {
        let core = SpyCore()
        return (GhostStateManager(core: core), core)
    }

    @MainActor
    func testInitialStateIsStopped() async {
        let (manager, core) = makeSUT()
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(manager.canTogglePause)
        XCTAssertTrue(core.calls.isEmpty)
    }

    @MainActor
    func testDefaultCoreIsIdle() async {
        XCTAssertTrue(GhostStateManager().core is IdleGhostCore)
    }

    @MainActor
    func testStartMakesGhostActive() async throws {
        let (manager, core) = makeSUT()
        try manager.start()
        XCTAssertEqual(manager.state, .active)
        XCTAssertTrue(manager.canTogglePause)
        XCTAssertEqual(core.calls, [.start])
    }

    @MainActor
    func testToggleSwitchesBetweenActiveAndPaused() async throws {
        let (manager, core) = makeSUT()
        try manager.start()

        try manager.togglePause()
        XCTAssertEqual(manager.state, .paused)

        try manager.togglePause()
        XCTAssertEqual(manager.state, .active)

        XCTAssertEqual(core.calls, [.start, .pause, .resume])
    }

    @MainActor
    func testToggleWhenStoppedThrowsAndChangesNothing() async {
        let (manager, core) = makeSUT()
        XCTAssertThrowsError(try manager.togglePause()) { error in
            XCTAssertEqual(error as? GhostTransitionError,
                           .invalidTransition(from: .stopped, to: .paused))
        }
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertTrue(core.calls.isEmpty)
    }

    @MainActor
    func testStartTwiceThrows() async throws {
        let (manager, core) = makeSUT()
        try manager.start()
        XCTAssertThrowsError(try manager.start())
        XCTAssertEqual(manager.state, .active)
        XCTAssertEqual(core.calls, [.start])
    }

    @MainActor
    func testPauseWhenNotActiveThrows() async {
        let (manager, _) = makeSUT()
        XCTAssertThrowsError(try manager.pause())
        XCTAssertEqual(manager.state, .stopped)
    }

    @MainActor
    func testResumeWhenNotPausedThrows() async throws {
        let (manager, core) = makeSUT()
        XCTAssertThrowsError(try manager.resume())   // depuis STOPPED
        try manager.start()
        XCTAssertThrowsError(try manager.resume())   // depuis ACTIVE
        XCTAssertEqual(manager.state, .active)
        XCTAssertEqual(core.calls, [.start])
    }

    @MainActor
    func testStopFromActive() async throws {
        let (manager, core) = makeSUT()
        try manager.start()
        manager.stop()
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertEqual(core.calls, [.start, .stop])
    }

    @MainActor
    func testStopFromPaused() async throws {
        let (manager, core) = makeSUT()
        try manager.start()
        try manager.pause()
        manager.stop()
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertEqual(core.calls, [.start, .pause, .stop])
    }

    @MainActor
    func testStopIsIdempotent() async throws {
        let (manager, core) = makeSUT()
        manager.stop()                     // déjà arrêté : aucun effet
        XCTAssertTrue(core.calls.isEmpty)

        try manager.start()
        manager.stop()
        manager.stop()
        XCTAssertEqual(core.calls, [.start, .stop])
    }

    @MainActor
    func testCanRestartAfterStop() async throws {
        let (manager, _) = makeSUT()
        try manager.start()
        manager.stop()
        try manager.start()
        XCTAssertEqual(manager.state, .active)
    }

    @MainActor
    func testCustomInitialState() async {
        let core = SpyCore()
        let paused = GhostStateManager(core: core, initialState: .paused)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertTrue(core.calls.isEmpty)
    }
}
