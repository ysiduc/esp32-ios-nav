//
//  NavigationIntegrationReplayTests.swift
//  P5.1 integration tests: true end-to-end navigation replay with real RerouteManager.
//
//  These tests verify the complete pipeline:
//  GPS sample → OffRouteDetector → RerouteManager → NavRoute → replaceActiveRoute
//  Without any manual replaceActiveRoute() calls in the test body.
//
//  The MockRoutingService from RerouteManagerTests is reused here via @testable import.
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

private func makeSample(coord: CLLocationCoordinate2D,
                         accuracy: Double = 5.0,
                         speed: Double = 8.0,
                         course: Double = 90.0,
                         ts: Date = Date()) -> CLLocation {
    CLLocation(
        coordinate: coord,
        altitude: 10,
        horizontalAccuracy: accuracy,
        verticalAccuracy: 5,
        course: course,
        speed: speed,
        timestamp: ts
    )
}

// MARK: - Integration Test Suite

@MainActor
final class NavigationIntegrationReplayTests: XCTestCase {

    var session: NavigationSessionManager!
    var mockRouting: MockRoutingService!
    var rerouteManager: RerouteManager!
    var runner: NavigationReplayRunner!

    let dest = NavigationDestination(coordinate: coordC, name: "Destination C")
    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    override func setUp() async throws {
        session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        mockRouting = MockRoutingService()
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
        // Arrange: route A and a reroute that will be returned (but not immediately resolved)
        let rerouteRoute = makeRerouteRoute(from: offRouteEastCoord(2))
        mockRouting.resultToReturn = .success(rerouteRoute)
        mockRouting.delayNanoseconds = 50_000_000 // 50ms simulated network

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
                                       accuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }

        XCTAssertTrue(session.isOffRoute, "Must be confirmed off-route after 5 east samples")

        // Allow async reroute task to start
        await Task.yield()

        // Assert: exactly one routing request was triggered
        XCTAssertEqual(mockRouting.callCount, 1,
                       "Exactly one reroute request must be issued for a single confirmed off-route event")
        XCTAssertTrue(rerouteManager.isRerouting,
                      "RerouteManager must be in isRerouting state while request is in-flight")
        XCTAssertTrue(session.isRerouting,
                      "NavSession.isRerouting must also be true while reroute is in-flight")
    }

    // MARK: - Test 2: Reroute commit is atomic — no manual replaceActiveRoute in test

    func testIntegration_RerouteCommit_AtomicStateTransition() async throws {
        // Arrange: a fast-resolving mock routing service
        let rerouteRoute = makeRerouteRoute(from: offRouteEastCoord(2))
        mockRouting.resultToReturn = .success(rerouteRoute)
        mockRouting.delayNanoseconds = 0 // resolve immediately

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
                                       accuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }

        XCTAssertTrue(session.isOffRoute)

        // Allow the Task in startReroute to resolve and commit
        await Task.yield()
        await Task.yield() // Two yields: one for the routing Task, one for the commit Task

        // Assert: Route B is active with NO manual replaceActiveRoute call in this test
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters,
                       rerouteRoute.totalDistanceMeters,
                       "Route B must be committed by RerouteManager without manual call")
        XCTAssertFalse(session.isRerouting,
                       "isRerouting must be cleared after successful commit")
        XCTAssertFalse(rerouteManager.isRerouting,
                       "RerouteManager.isRerouting must also be cleared")
        XCTAssertEqual(session.state, .navigating,
                       "Session must remain in .navigating after reroute commit")
    }

    // MARK: - Test 3: Backoff with real RerouteManager and failing service

    func testIntegration_RerouteBackoff_RealManager() async {
        // Arrange: routing always fails
        mockRouting.resultToReturn = .failure(NSError(domain: "routing", code: -1,
                                                       userInfo: [NSLocalizedDescriptionKey: "Network error"]))
        mockRouting.delayNanoseconds = 0

        let clock = TestClock(date: baseDate)
        let timedRerouteManager = RerouteManager(
            routingService: mockRouting,
            navSession: session,
            now: { clock.currentDate }
        )
        session.onOffRouteDecision = { [weak timedRerouteManager] decision, location in
            timedRerouteManager?.handleObservation(location: location, decision: decision)
        }

        session.startNavigation(route: makeStraightRoute(), destination: dest)

        // Trigger off-route
        for i in 0..<5 {
            let ts = baseDate.addingTimeInterval(Double(i))
            runner.replay(samples: [
                NavigationReplaySample(timestamp: ts,
                                       coordinate: offRouteEastCoord(i),
                                       accuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }

        // Wait for first failing attempt
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(mockRouting.callCount, 1, "First off-route event triggers one request")
        XCTAssertFalse(timedRerouteManager.isRerouting, "After failure, isRerouting must be false")
        XCTAssertEqual(timedRerouteManager.failureCount, 1, "Failure count must increment")
        XCTAssertNotNil(timedRerouteManager.nextEligibleRerouteAt,
                        "Backoff delay must be set after first failure")

        // Advance clock past backoff delay (first delay is 2.0s)
        guard let nextAt = timedRerouteManager.nextEligibleRerouteAt else { return }
        clock.currentDate = nextAt.addingTimeInterval(0.1)

        // Replay another off-route observation — this time backoff has expired
        let laterTS = baseDate.addingTimeInterval(10)
        runner.replay(samples: [
            NavigationReplaySample(timestamp: laterTS,
                                   coordinate: offRouteEastCoord(3),
                                   accuracy: 5.0, speed: 8.0, course: 90.0)
        ])

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(mockRouting.callCount, 2,
                       "After backoff expires, second off-route observation triggers second request")
        XCTAssertEqual(timedRerouteManager.failureCount, 2,
                       "Failure count must continue incrementing")
    }

    // MARK: - Test 4: Full end-to-end — wrong turn, reroute, arrival; no manual commit

    func testIntegration_FullEndToEnd_NoManualRouteCommit() async throws {
        // Arrange
        let rerouteRoute = makeRerouteRoute(from: offRouteEastCoord(2))
        mockRouting.resultToReturn = .success(rerouteRoute)
        mockRouting.delayNanoseconds = 0

        var arrivedFired = false
        session.onArrived = { arrivedFired = true }

        session.startNavigation(route: makeStraightRoute(), destination: dest)

        // Phase 1: On-route progress
        runner.replay(samples: [
            NavigationReplaySample(timestamp: baseDate, coordinate: coordA),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(5), coordinate: coordB)
        ])
        XCTAssertFalse(session.isOffRoute)

        // Phase 2: Wrong turn — diverge east
        for i in 0..<5 {
            runner.replay(samples: [
                NavigationReplaySample(timestamp: baseDate.addingTimeInterval(10 + Double(i)),
                                       coordinate: offRouteEastCoord(i),
                                       accuracy: 5.0, speed: 8.0, course: 90.0)
            ])
        }
        XCTAssertTrue(session.isOffRoute, "Must confirm off-route after eastward divergence")

        // Phase 3: RerouteManager commits Route B (no manual replaceActiveRoute)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, rerouteRoute.totalDistanceMeters,
                       "Route B must be committed by real RerouteManager")
        XCTAssertFalse(session.isRerouting, "isRerouting must be false after commit")
        XCTAssertEqual(session.state, .navigating)

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
                accuracy: 5.0, speed: 8.0, course: 0.0
            ))
        }
        // Phase 5: Settle at destination (Kalman convergence → arrival)
        samplesB.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(70),
            coordinate: coordC, accuracy: 5.0, speed: 0.0
        ))
        samplesB.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(72),
            coordinate: coordC, accuracy: 5.0, speed: 0.0
        ))
        runner.replay(samples: samplesB)

        XCTAssertEqual(runner.arrivalCount, 1,
                       "Arrival must fire exactly once after convergence at destination")
        XCTAssertEqual(session.state, .arrived, "Session must be .arrived")
        XCTAssertNotEqual(session.trackingProfile, .activeNavigation,
                          "Tracking profile must be downgraded from activeNavigation on arrival")
        _ = arrivedFired  // arrival callback also fired — checked via runner.arrivalCount
    }
}
