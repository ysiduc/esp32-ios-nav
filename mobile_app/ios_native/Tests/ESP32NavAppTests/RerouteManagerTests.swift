//
//  RerouteManagerTests.swift
//  Deterministic unit tests for RerouteManager policy, retry backoff, and generation safety.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

// MARK: - Mock Routing Service

@MainActor
final class MockRoutingService: RoutingServiceProtocol {
    var callCount: Int = 0
    var lastOrigin: CLLocationCoordinate2D?
    var lastDestination: CLLocationCoordinate2D?
    var lastCosting: String?

    var resultToReturn: Result<NavRoute, Error> = .failure(NSError(domain: "test", code: -1))
    var delayNanoseconds: UInt64 = 0

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        callCount += 1
        lastOrigin = origin
        lastDestination = destination
        lastCosting = costing

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        switch resultToReturn {
        case .success(let route):
            return route
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Test Suite

@MainActor
final class RerouteManagerTests: XCTestCase {

    var navSession: NavigationSessionManager!
    var mockRouting: MockRoutingService!
    var rerouteManager: RerouteManager!

    let baseDate = Date(timeIntervalSince1970: 1700000000.0)
    var destination: NavigationDestination!
    var initialRoute: NavRoute!
    var replacementRoute: NavRoute!

    override func setUp() {
        super.setUp()
        navSession = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        mockRouting = MockRoutingService()
        rerouteManager = RerouteManager(routingService: mockRouting, navSession: navSession)

        let coordsA = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0)
        ]
        let step0 = NavStep(coordinate: coordsA[0], distanceMeters: 300.0, durationSeconds: 30.0, streetName: "A", maneuverType: .depart, instruction: "Depart")
        let stepA = NavStep(coordinate: coordsA[1], distanceMeters: 256.0, durationSeconds: 30.0, streetName: "A", maneuverType: .arrive, instruction: "Arrive")
        initialRoute = NavRoute(coordinates: coordsA, steps: [step0, stepA], totalDistanceMeters: 556.0, totalDurationSeconds: 60.0)
        destination = NavigationDestination(coordinate: coordsA[1], name: "Goal")

        let coordsB = [
            CLLocationCoordinate2D(latitude: 10.001, longitude: 106.001),
            CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0)
        ]
        let stepB0 = NavStep(coordinate: coordsB[0], distanceMeters: 250.0, durationSeconds: 25.0, streetName: "B", maneuverType: .depart, instruction: "Depart")
        let stepB = NavStep(coordinate: coordsB[1], distanceMeters: 250.0, durationSeconds: 25.0, streetName: "B", maneuverType: .arrive, instruction: "Arrive")
        replacementRoute = NavRoute(coordinates: coordsB, steps: [stepB0, stepB], totalDistanceMeters: 500.0, totalDurationSeconds: 50.0)

        navSession.startNavigation(route: initialRoute, destination: destination)
    }

    override func tearDown() {
        rerouteManager?.cancel()
        navSession?.stopNavigation()
        rerouteManager = nil
        navSession = nil
        mockRouting = nil
        destination = nil
        initialRoute = nil
        replacementRoute = nil
        super.tearDown()
    }

    // MARK: - Test 1: Single In-Flight Request Guarantee (No Concurrent Reroutes)

    func testSingleInFlightRequestGuarantee() async {
        mockRouting.delayNanoseconds = 100_000_000 // 100ms
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let confirmedDecision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .sustainedLateralDeviation,
            lateralDistanceMeters: 25.0,
            activeThresholdMeters: 15.0
        )

        // Fire observation 1 -> starts request
        rerouteManager.handleObservation(location: loc, decision: confirmedDecision, currentTime: baseDate)
        XCTAssertTrue(rerouteManager.isRerouting)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.callCount, 1)

        // Fire observation 2 and 3 while request 1 is still in flight
        rerouteManager.handleObservation(location: loc, decision: confirmedDecision, currentTime: baseDate.addingTimeInterval(0.02))
        rerouteManager.handleObservation(location: loc, decision: confirmedDecision, currentTime: baseDate.addingTimeInterval(0.04))

        // Call count MUST remain exactly 1! (No duplicate/storm requests)
        XCTAssertEqual(mockRouting.callCount, 1)

        // Await completion
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(rerouteManager.isRerouting)
    }

    // MARK: - Test 2: Bounded Backoff Retry After Failure

    func testBoundedBackoffRetryAfterFailure() async {
        mockRouting.resultToReturn = .failure(NSError(domain: "test", code: 500))

        let loc1 = CLLocation(latitude: 10.001, longitude: 106.001)
        let confirmedDecision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .sustainedLateralDeviation,
            lateralDistanceMeters: 25.0,
            activeThresholdMeters: 15.0
        )

        // Attempt 1 fails
        rerouteManager.handleObservation(location: loc1, decision: confirmedDecision, currentTime: baseDate)
        try? await Task.sleep(nanoseconds: 10_000_000) // allow task to execute and catch error

        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertEqual(rerouteManager.failureCount, 1)
        XCTAssertNotNil(rerouteManager.nextEligibleRerouteAt)
        // 1st failure backoff delay is 2.0s
        XCTAssertEqual(rerouteManager.nextEligibleRerouteAt, baseDate.addingTimeInterval(2.0))

        // Observation before backoff expires (t = 1.0s) -> No retry
        rerouteManager.handleObservation(location: loc1, decision: confirmedDecision, currentTime: baseDate.addingTimeInterval(1.0))
        XCTAssertEqual(mockRouting.callCount, 1)

        // Observation after backoff expires (t = 2.1s) -> Attempt 2 triggered without requiring onRoute return!
        rerouteManager.handleObservation(location: loc1, decision: confirmedDecision, currentTime: baseDate.addingTimeInterval(2.1))
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.callCount, 2)
    }

    // MARK: - Test 3: Retry Uses Fresh Physical Origin When Vehicle Moves

    func testRetryUsesFreshPhysicalOrigin() async {
        mockRouting.resultToReturn = .failure(NSError(domain: "network", code: -1009))

        let locA = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        // Attempt 1 from origin A
        rerouteManager.handleObservation(location: locA, decision: decision, currentTime: baseDate)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.lastOrigin?.latitude, 10.001)

        // Vehicle moves to origin B
        let locB = CLLocation(latitude: 10.003, longitude: 106.004)

        // Attempt 2 after backoff (t = 2.5s)
        rerouteManager.handleObservation(location: locB, decision: decision, currentTime: baseDate.addingTimeInterval(2.5))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(mockRouting.callCount, 2)
        XCTAssertEqual(mockRouting.lastOrigin?.latitude, 10.003, "Retry must use latest physical coordinates")
        XCTAssertEqual(mockRouting.lastOrigin?.longitude, 106.004)
    }

    // MARK: - Test 4: Frozen Destination Preserved Across Retries

    func testFrozenDestinationPreservedAcrossRetries() async {
        mockRouting.resultToReturn = .failure(NSError(domain: "test", code: 503))

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate)
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(mockRouting.lastDestination?.latitude, destination.coordinate.latitude)
        XCTAssertEqual(mockRouting.lastDestination?.longitude, destination.coordinate.longitude)
    }

    // MARK: - Test 5: Stop Navigation Cancels Reroute and Discards Response

    func testStopNavigationCancelsRerouteAndDiscardsResponse() async {
        mockRouting.delayNanoseconds = 100_000_000 // 100ms
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate)
        XCTAssertTrue(rerouteManager.isRerouting)

        // Stop navigation while request is in flight
        rerouteManager.cancel()
        navSession.stopNavigation()

        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertNil(rerouteManager.nextEligibleRerouteAt)

        // Wait for late response
        try? await Task.sleep(nanoseconds: 150_000_000)

        // State remains idle; route was NOT resurrected
        XCTAssertEqual(navSession.state, .idle)
        XCTAssertNil(navSession.activeRoute)
    }

    // MARK: - Test 6: Stale Response From Obsolete Session Discarded

    func testStaleResponseFromObsoleteSessionDiscarded() async {
        mockRouting.delayNanoseconds = 100_000_000
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate)

        // Simulate new session starting before reroute finishes
        navSession.stopNavigation()
        navSession.startNavigation(route: initialRoute, destination: destination)
        let newSessionGen = navSession.sessionGeneration

        try? await Task.sleep(nanoseconds: 150_000_000)

        // Active route in Session B was NOT replaced by Session A's reroute!
        XCTAssertEqual(navSession.sessionGeneration, newSessionGen)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 556.0)
    }

    // MARK: - Test 7: Active Route Revision Race Discards Superseded Reroute

    func testActiveRouteRevisionRaceDiscardsSupersededReroute() async {
        mockRouting.delayNanoseconds = 100_000_000
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate)

        // An alternate authoritative route update replaces Route A while reroute is computing
        let coordsC = [CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0), CLLocationCoordinate2D(latitude: 10.008, longitude: 106.0)]
        let routeC = NavRoute(coordinates: coordsC, steps: [NavStep(coordinate: coordsC[1], distanceMeters: 800.0, durationSeconds: 80.0, streetName: "C", maneuverType: .arrive, instruction: "Arrive")], totalDistanceMeters: 800.0, totalDurationSeconds: 80.0)
        navSession.replaceActiveRoute(routeC)
        let routeCGeneration = navSession.activeRouteGeneration

        try? await Task.sleep(nanoseconds: 150_000_000)

        // Route C must NOT be overwritten by the obsolete reroute response!
        XCTAssertEqual(navSession.activeRouteGeneration, routeCGeneration)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 800.0)
    }

    // MARK: - Test 8: Successful Atomic Route B Replacement

    func testSuccessfulAtomicRouteBReplacement() async {
        mockRouting.resultToReturn = .success(replacementRoute)

        let initialSessionGen = navSession.sessionGeneration
        let initialRouteGen = navSession.activeRouteGeneration

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate)

        try? await Task.sleep(nanoseconds: 10_000_000)

        // Verifications:
        XCTAssertEqual(navSession.sessionGeneration, initialSessionGen, "Session generation unchanged")
        XCTAssertEqual(navSession.activeRouteGeneration, initialRouteGen + 1, "Route revision incremented atomically")
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 500.0, "Active route is Route B")
        XCTAssertEqual(navSession.navigationDestination?.name, "Goal", "Destination preserved")
        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertEqual(rerouteManager.failureCount, 0)
        XCTAssertNil(rerouteManager.nextEligibleRerouteAt)
        XCTAssertNotNil(rerouteManager.lastCommittedAt)
    }

    // MARK: - Test 9: Recovery Cancels In-Flight Off-Route Request

    func testRecoveryCancelsInFlightOffRouteRequest() async {
        mockRouting.delayNanoseconds = 100_000_000
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let confirmedDecision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: confirmedDecision, currentTime: baseDate)
        XCTAssertTrue(rerouteManager.isRerouting)

        // User returns to route before reroute finishes
        let recoveredDecision = OffRouteDecision(state: .onRoute, becameConfirmed: false, recovered: true, reason: .recoveredToRoute, lateralDistanceMeters: 3.0, activeThresholdMeters: 10.0)
        rerouteManager.handleObservation(location: loc, decision: recoveredDecision, currentTime: baseDate.addingTimeInterval(0.05))

        XCTAssertFalse(rerouteManager.isRerouting, "In-flight off-route request must be cancelled upon recovery")

        try? await Task.sleep(nanoseconds: 150_000_000)

        // Original route preserved
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 556.0)
    }

    // MARK: - Test 10: Transport Mode Change Supersedes and Ignores Backoff

    func testTransportModeChangeSupersedesAndIgnoresBackoff() async {
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.001, longitude: 106.001),
            altitude: 0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            timestamp: baseDate
        )
        navSession.filteredLocation = loc
        navSession.userLocation = loc

        // Simulate failure backoff active
        rerouteManager.startReroute(reason: .offRoute, origin: loc.coordinate, costing: "motorcycle", currentTime: baseDate)
        mockRouting.resultToReturn = .failure(NSError(domain: "test", code: -1))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertNotNil(rerouteManager.nextEligibleRerouteAt)

        // User changes transport mode to auto -> MUST bypass backoff!
        mockRouting.resultToReturn = .success(replacementRoute)
        rerouteManager.requestTransportModeReroute(costing: "auto", origin: loc.coordinate, currentTime: baseDate.addingTimeInterval(0.5))

        XCTAssertEqual(rerouteManager.currentReason, .transportModeChanged)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.lastCosting, "auto")

        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 500.0)
    }
}
