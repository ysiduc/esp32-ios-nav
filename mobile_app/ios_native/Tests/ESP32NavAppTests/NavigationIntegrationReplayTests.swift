//
//  NavigationIntegrationReplayTests.swift
//  P5.1 integration tests: true end-to-end navigation replay with real RerouteManager.
//
//  These tests verify the complete pipeline:
//  GPS sample → OffRouteDetector → RerouteManager → ControlledRoutingService → replaceActiveRoute
//  Without any manual replaceActiveRoute() calls in the test body.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

// MARK: - Integration Helpers

private let coordA = CLLocationCoordinate2D(latitude: 21.0280, longitude: 105.8542)
private let coordB = CLLocationCoordinate2D(latitude: 21.0340, longitude: 105.8542)
private let coordC = CLLocationCoordinate2D(latitude: 21.0385, longitude: 105.8542)

private func makeStraightRoute() -> NavRoute {
    NavRoute(
        coordinates: [coordA, coordB, coordC],
        steps: [
            NavStep(coordinate: coordB, distanceMeters: 667, durationSeconds: 67,
                    streetName: "Nguyen Van Linh", maneuverType: .straight, instruction: "Go north"),
            NavStep(coordinate: coordC, distanceMeters: 500, durationSeconds: 50,
                    streetName: "Tran Hung Dao", maneuverType: .arrive, instruction: "Arrived")
        ],
        totalDistanceMeters: 1167, totalDurationSeconds: 117
    )
}

private func makeRerouteRoute(from: CLLocationCoordinate2D) -> NavRoute {
    NavRoute(
        coordinates: [from, coordC],
        steps: [
            NavStep(coordinate: coordC, distanceMeters: 600, durationSeconds: 60,
                    streetName: "Alt Street", maneuverType: .arrive, instruction: "Arrived")
        ],
        totalDistanceMeters: 600, totalDurationSeconds: 60
    )
}

private func offRouteEastCoord(_ i: Int) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: 21.0340, longitude: 105.8550 + Double(i) * 0.0002)
}

// MARK: - Controlled Async Fake for Deterministic Rerouting

final class ControlledRoutingService: RoutingServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount: Int = 0
    private var _lastOrigin: CLLocationCoordinate2D?
    private var _lastDestination: CLLocationCoordinate2D?
    private var _lastCosting: String?

    var onRequestStarted: (@Sendable () -> Void)?
    private var pendingContinuation: CheckedContinuation<NavRoute, Error>?
    var autoResult: Result<NavRoute, Error>?

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var lastOrigin: CLLocationCoordinate2D? {
        lock.lock()
        defer { lock.unlock() }
        return _lastOrigin
    }

    var lastDestination: CLLocationCoordinate2D? {
        lock.lock()
        defer { lock.unlock() }
        return _lastDestination
    }

    var lastCosting: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastCosting
    }

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        lock.lock()
        _callCount += 1
        _lastOrigin = origin
        _lastDestination = destination
        _lastCosting = costing
        let onStarted = onRequestStarted
        let auto = autoResult
        lock.unlock()

        onStarted?()

        if let auto = auto {
            switch auto {
            case .success(let route): return route
            case .failure(let err): throw err
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.pendingContinuation = continuation
            lock.unlock()
        }
    }

    func resolve(with result: Result<NavRoute, Error>) {
        lock.lock()
        let continuation = pendingContinuation
        pendingContinuation = nil
        lock.unlock()

        switch result {
        case .success(let route):
            continuation?.resume(returning: route)
        case .failure(let err):
            continuation?.resume(throwing: err)
        }
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2.0,
    intervalMs: UInt64 = 10,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
    }
    return condition()
}

// MARK: - Integration Test Suite

@MainActor
final class NavigationIntegrationReplayTests: XCTestCase {

    var session: NavigationSessionManager!
    var mockRouting: ControlledRoutingService!
    var rerouteManager: RerouteManager!
    var runner: NavigationReplayRunner!

    let dest = NavigationDestination(coordinate: coordC, name: "Destination C")
    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    override func setUp() async throws {
        session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        mockRouting = ControlledRoutingService()
        rerouteManager = RerouteManager(routingService: mockRouting, navSession: session)
        runner = NavigationReplayRunner(sessionManager: session)

        // Wire the real RerouteManager as the off-route handler
        session.onOffRouteDecision = { [weak self] decision, location in
            guard let self = self else { return }
            self.rerouteManager.handleObservation(
                location: location,
                decision: decision,
                costing: "motorcycle"
            )
        }
    }

    override func tearDown() async throws {
        session = nil
        mockRouting = nil
        rerouteManager = nil
        runner = nil
    }

    // MARK: - Test 1: Wrong turn triggers exactly one real reroute request

    func testIntegration_WrongTurn_TriggersRealRerouteRequest() async {
        let rerouteRoute = makeRerouteRoute(from: offRouteEastCoord(2))

        let requestStartedExpectation = expectation(description: "Routing request started")
        mockRouting.onRequestStarted = {
            requestStartedExpectation.fulfill()
        }

        session.startNavigation(route: makeStraightRoute(), destination: dest)

        // Act: replay on-route samples, then diverge east for 5 frames (off-route confirmed)
        runner.replay(samples: [
            NavigationReplaySample(timestamp: baseDate, coordinate: coordA, speed: 8.0, course: 0.0),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(5), coordinate: coordB, speed: 8.0, course: 0.0)
        ])
        XCTAssertFalse(session.isOffRoute, "Must be on-route before divergence")

        for i in 0..<5 {
            let ts = baseDate.addingTimeInterval(10 + Double(i))
            runner.replay(samples: [
                NavigationReplaySample(timestamp: ts,
                                       coordinate: offRouteEastCoord(i),
                                       horizontalAccuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }

        XCTAssertTrue(session.isOffRoute, "Must be confirmed off-route after 5 east samples")

        // Await until routing request starts deterministically
        await fulfillment(of: [requestStartedExpectation], timeout: 2.0)

        // Assert: exactly one routing request was triggered and is in-flight
        XCTAssertEqual(mockRouting.callCount, 1,
                       "Exactly one reroute request must be issued for a single confirmed off-route event")
        XCTAssertTrue(rerouteManager.isRerouting,
                      "RerouteManager must be in isRerouting state while request is in-flight")
        XCTAssertTrue(session.isRerouting,
                      "NavSession.isRerouting must also be true while reroute is in-flight")

        // Cleanup: resolve in-flight request so Task completes cleanly
        mockRouting.resolve(with: .success(rerouteRoute))
    }

    // MARK: - Test 2: Reroute commit is atomic — no manual replaceActiveRoute in test

    func testIntegration_RerouteCommit_AtomicStateTransition() async throws {
        let rerouteRoute = makeRerouteRoute(from: offRouteEastCoord(2))

        let requestStartedExp = expectation(description: "Routing request started")
        mockRouting.onRequestStarted = {
            requestStartedExp.fulfill()
        }

        session.startNavigation(route: makeStraightRoute(), destination: dest)

        // Prime a filtered location so replaceActiveRoute can immediately reproject
        runner.replay(samples: [
            NavigationReplaySample(timestamp: baseDate, coordinate: coordA)
        ])

        // Trigger off-route to kick off reroute via RerouteManager
        for i in 0..<5 {
            let ts = baseDate.addingTimeInterval(5 + Double(i))
            runner.replay(samples: [
                NavigationReplaySample(timestamp: ts,
                                       coordinate: offRouteEastCoord(i),
                                       horizontalAccuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }

        XCTAssertTrue(session.isOffRoute)

        // Await request start deterministically
        await fulfillment(of: [requestStartedExp], timeout: 2.0)

        // Explicitly resolve continuation with Route B
        mockRouting.resolve(with: .success(rerouteRoute))

        // Deterministically wait until commit condition is true
        let committed = await waitUntil { [weak self] in
            self?.session.activeRoute?.totalDistanceMeters == rerouteRoute.totalDistanceMeters
        }
        XCTAssertTrue(committed, "Route B must be committed by RerouteManager without manual replaceActiveRoute call")

        XCTAssertFalse(session.isRerouting, "isRerouting must be cleared after successful commit")
        XCTAssertFalse(rerouteManager.isRerouting, "RerouteManager.isRerouting must also be cleared")
        XCTAssertEqual(session.state, .navigating, "Session must remain in .navigating after reroute commit")
    }

    // MARK: - Test 3: Backoff with real RerouteManager and failing service

    func testIntegration_RerouteBackoff_RealManager() async {
        let clock = TestClock(date: baseDate)
        let timedRerouteManager = RerouteManager(
            routingService: mockRouting,
            navSession: session,
            now: { clock.currentDate }
        )
        session.onOffRouteDecision = { [weak timedRerouteManager] decision, location in
            timedRerouteManager?.handleObservation(location: location, decision: decision)
        }

        var req1Exp: XCTestExpectation? = expectation(description: "First request started")
        mockRouting.onRequestStarted = {
            req1Exp?.fulfill()
            req1Exp = nil
        }

        session.startNavigation(route: makeStraightRoute(), destination: dest)

        // Trigger off-route
        for i in 0..<5 {
            let ts = baseDate.addingTimeInterval(Double(i))
            runner.replay(samples: [
                NavigationReplaySample(timestamp: ts,
                                       coordinate: offRouteEastCoord(i),
                                       horizontalAccuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }

        // Wait for first request to start
        await fulfillment(of: [req1Exp!], timeout: 2.0)

        // Resolve request 1 with failure
        mockRouting.resolve(with: .failure(NSError(domain: "routing", code: -1,
                                                   userInfo: [NSLocalizedDescriptionKey: "Network error"])))

        // Wait until isRerouting becomes false after failure
        let failed = await waitUntil { !timedRerouteManager.isRerouting }
        XCTAssertTrue(failed, "RerouteManager must clear isRerouting after failure")
        XCTAssertEqual(mockRouting.callCount, 1, "First off-route event triggers one request")
        XCTAssertEqual(timedRerouteManager.failureCount, 1, "Failure count must increment")
        XCTAssertNotNil(timedRerouteManager.nextEligibleRerouteAt, "Backoff delay must be set after first failure")

        // Advance clock past backoff delay (first delay is 2.0s)
        guard let nextAt = timedRerouteManager.nextEligibleRerouteAt else { return }
        clock.currentDate = nextAt.addingTimeInterval(0.1)

        var req2Exp: XCTestExpectation? = expectation(description: "Second request started")
        mockRouting.onRequestStarted = {
            req2Exp?.fulfill()
            req2Exp = nil
        }

        // Replay another off-route observation — backoff has now expired
        let laterTS = baseDate.addingTimeInterval(10)
        runner.replay(samples: [
            NavigationReplaySample(timestamp: laterTS,
                                   coordinate: offRouteEastCoord(3),
                                   horizontalAccuracy: 5.0, speed: 8.0, course: 90.0)
        ])

        await fulfillment(of: [req2Exp!], timeout: 2.0)

        XCTAssertEqual(mockRouting.callCount, 2,
                       "After backoff expires, second off-route observation triggers second request")
        mockRouting.resolve(with: .failure(NSError(domain: "routing", code: -1)))
        let secondFailed = await waitUntil { !timedRerouteManager.isRerouting }
        XCTAssertTrue(secondFailed)
        XCTAssertEqual(timedRerouteManager.failureCount, 2, "Failure count must continue incrementing")
    }

    // MARK: - Test 4: Full end-to-end — wrong turn, reroute, arrival; proving frozen session invariants

    func testIntegration_FullEndToEnd_NoManualRouteCommit() async throws {
        let rerouteRoute = makeRerouteRoute(from: offRouteEastCoord(2))

        var arrivedFired = false
        let runnerOnArrived = session.onArrived
        session.onArrived = {
            arrivedFired = true
            runnerOnArrived?()
        }

        var rerouteExp: XCTestExpectation? = expectation(description: "Reroute request started")
        mockRouting.onRequestStarted = {
            rerouteExp?.fulfill()
            rerouteExp = nil
        }

        session.startNavigation(route: makeStraightRoute(), destination: dest)

        // Phase 1: On-route progress
        runner.replay(samples: [
            NavigationReplaySample(timestamp: baseDate, coordinate: coordA, speed: 8.0, course: 0.0),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(5), coordinate: coordB, speed: 8.0, course: 0.0)
        ])
        XCTAssertFalse(session.isOffRoute)

        // Record frozen session invariants before wrong turn capture
        let preSessionGen = session.sessionGeneration
        let preDestCoord  = session.navigationDestination?.coordinate
        let preDestName   = session.navigationDestination?.name
        let preRouteGen   = session.activeRouteGeneration

        // Phase 2: Wrong turn — diverge east
        for i in 0..<5 {
            runner.replay(samples: [
                NavigationReplaySample(timestamp: baseDate.addingTimeInterval(10 + Double(i)),
                                       coordinate: offRouteEastCoord(i),
                                       horizontalAccuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }
        XCTAssertTrue(session.isOffRoute, "Must confirm off-route after eastward divergence")

        // Wait for reroute request to start
        await fulfillment(of: [rerouteExp!], timeout: 2.0)

        // Phase 3: RerouteManager commits Route B (no manual replaceActiveRoute)
        mockRouting.resolve(with: .success(rerouteRoute))

        let committed = await waitUntil { [weak self] in
            self?.session.activeRoute?.totalDistanceMeters == rerouteRoute.totalDistanceMeters
        }
        XCTAssertTrue(committed, "Route B must be committed by real RerouteManager")

        // Assert frozen session invariants required by P5.1
        XCTAssertEqual(session.sessionGeneration, preSessionGen, "sessionGeneration must remain unchanged after reroute")
        XCTAssertEqual(session.navigationDestination?.coordinate.latitude, preDestCoord?.latitude, "destination lat unchanged")
        XCTAssertEqual(session.navigationDestination?.coordinate.longitude, preDestCoord?.longitude, "destination lon unchanged")
        XCTAssertEqual(session.navigationDestination?.name, preDestName, "destination name unchanged")
        XCTAssertEqual(session.activeRouteGeneration, preRouteGen + 1, "activeRouteGeneration must bump by exactly 1")
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, rerouteRoute.totalDistanceMeters, "Route B active")
        XCTAssertFalse(session.isRerouting, "session.isRerouting must be false after commit")
        XCTAssertFalse(rerouteManager.isRerouting, "rerouteManager.isRerouting must be false after commit")
        XCTAssertEqual(session.state, .navigating, "Session must remain navigating")
        XCTAssertNotNil(session.currentProjection, "currentProjection must be recomputed against Route B")

        // Phase 4: Progress on Route B toward coordC
        let startB = offRouteEastCoord(2)
        var samplesB: [NavigationReplaySample] = []
        for i in 0...3 {
            let frac = Double(i) / 3.0
            let lat = startB.latitude + frac * (coordC.latitude - startB.latitude)
            let lon = startB.longitude + frac * (coordC.longitude - startB.longitude)
            samplesB.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(25 + Double(i) * 10),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                horizontalAccuracy: 5.0, speed: 8.0, course: 0.0
            ))
        }
        // Phase 5: Settle at destination (Kalman convergence → arrival)
        samplesB.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(70),
            coordinate: coordC, horizontalAccuracy: 5.0, speed: 0.0
        ))
        samplesB.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(72),
            coordinate: coordC, horizontalAccuracy: 5.0, speed: 0.0
        ))
        runner.replay(samples: samplesB)

        XCTAssertEqual(runner.arrivalCount, 1,
                       "Arrival must fire exactly once after convergence at destination")
        XCTAssertEqual(session.state, .arrived, "Session must be .arrived")
        XCTAssertNotEqual(session.trackingProfile, .activeNavigation,
                          "Tracking profile must be downgraded from activeNavigation on arrival")
        XCTAssertTrue(arrivedFired, "onArrived callback must have fired")
    }
}
