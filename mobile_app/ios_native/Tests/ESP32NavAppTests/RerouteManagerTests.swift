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

    var simulatedNow: Date = Date(timeIntervalSince1970: 1700000000.0)
    let baseDate = Date(timeIntervalSince1970: 1700000000.0)
    var destination: NavigationDestination!
    var initialRoute: NavRoute!
    var replacementRoute: NavRoute!

    override func setUp() {
        super.setUp()
        simulatedNow = baseDate
        navSession = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        mockRouting = MockRoutingService()
        rerouteManager = RerouteManager(
            routingService: mockRouting,
            navSession: navSession,
            now: { [weak self] in self?.simulatedNow ?? Date() }
        )

        let coordsA = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0)
        ]
        let step0 = NavStep(coordinate: coordsA[0], distanceMeters: 300.0, durationSeconds: 30.0, streetName: "A", maneuverType: .straight, instruction: "Straight")
        let stepA = NavStep(coordinate: coordsA[1], distanceMeters: 256.0, durationSeconds: 30.0, streetName: "A", maneuverType: .arrive, instruction: "Arrive")
        initialRoute = NavRoute(coordinates: coordsA, steps: [step0, stepA], totalDistanceMeters: 556.0, totalDurationSeconds: 60.0)
        destination = NavigationDestination(coordinate: coordsA[1], name: "Goal")

        let coordsB = [
            CLLocationCoordinate2D(latitude: 10.001, longitude: 106.001),
            CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0)
        ]
        let stepB0 = NavStep(coordinate: coordsB[0], distanceMeters: 250.0, durationSeconds: 25.0, streetName: "B", maneuverType: .straight, instruction: "Straight")
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
        simulatedNow = baseDate.addingTimeInterval(2.1)
        rerouteManager.handleObservation(location: loc1, decision: confirmedDecision, currentTime: simulatedNow)
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
        simulatedNow = baseDate.addingTimeInterval(2.5)
        rerouteManager.handleObservation(location: locB, decision: decision, currentTime: simulatedNow)
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

    // MARK: - Test 9: Recovery Cancels In-Flight Off-Route Request Without Fake Failure

    func testRecoveryCancelsInFlightOffRouteRequest() async {
        mockRouting.delayNanoseconds = 100_000_000
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let confirmedDecision = OffRouteDecision(state: .confirmed, becameConfirmed: true, recovered: false, reason: .sustainedLateralDeviation, lateralDistanceMeters: 25.0, activeThresholdMeters: 15.0)

        rerouteManager.handleObservation(location: loc, decision: confirmedDecision, currentTime: baseDate)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(rerouteManager.isRerouting)

        // User returns to route before reroute finishes
        let recoveredDecision = OffRouteDecision(state: .onRoute, becameConfirmed: false, recovered: true, reason: .recoveredToRoute, lateralDistanceMeters: 3.0, activeThresholdMeters: 10.0)
        rerouteManager.handleObservation(location: loc, decision: recoveredDecision, currentTime: baseDate.addingTimeInterval(0.05))

        XCTAssertFalse(rerouteManager.isRerouting, "In-flight off-route request must be cancelled upon recovery")

        // Wait for cancelled async routing task and catch block to fully unwind
        try? await Task.sleep(nanoseconds: 150_000_000)

        // P2.1 verification: assert cancellation was NOT counted as failure!
        XCTAssertEqual(rerouteManager.failureCount, 0, "Cancellation due to recovery must NOT increment failureCount")
        XCTAssertNil(rerouteManager.nextEligibleRerouteAt, "Cancellation due to recovery must NOT schedule backoff retry")
        XCTAssertNil(rerouteManager.currentReason, "currentReason must be nil after recovery")
        XCTAssertFalse(rerouteManager.isRerouting, "isRerouting must remain false")
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 556.0, "Original route preserved")
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

        // Simulate failure backoff active from previous off-route attempt
        rerouteManager.startReroute(reason: .offRoute, origin: loc.coordinate, costing: "motorcycle")
        mockRouting.resultToReturn = .failure(NSError(domain: "test", code: -1))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertNotNil(rerouteManager.nextEligibleRerouteAt, "Off-route failure schedules backoff")

        // User changes transport mode to auto -> MUST bypass backoff!
        mockRouting.resultToReturn = .success(replacementRoute)
        rerouteManager.requestTransportModeReroute(costing: "auto", origin: loc.coordinate)

        XCTAssertEqual(rerouteManager.currentReason, .transportModeChanged)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.lastCosting, "auto")

        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 500.0)
    }

    // MARK: - Test 11 (P2.1): Failure Backoff Begins at Failure Completion Time Not Request Start

    func testFailureBackoffBeginsAtFailureCompletionTimeNotRequestStart() async {
        simulatedNow = Date(timeIntervalSince1970: 100.0)
        mockRouting.resultToReturn = .failure(NSError(domain: "test", code: 504))
        mockRouting.delayNanoseconds = 50_000_000 // 50ms simulated async latency

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .sustainedLateralDeviation,
            lateralDistanceMeters: 25.0,
            activeThresholdMeters: 15.0
        )

        // Request starts at t=100.0
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: simulatedNow)
        XCTAssertTrue(rerouteManager.isRerouting)

        // Advance simulated clock to t=106.0 while routing request is pending
        simulatedNow = Date(timeIntervalSince1970: 106.0)

        // Allow routing failure to complete
        try? await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertEqual(rerouteManager.failureCount, 1)

        // Backoff MUST be anchored to failure completion time (106.0 + 2.0 = 108.0s), NOT request start (100.0 + 2.0 = 102.0s)!
        XCTAssertEqual(
            rerouteManager.nextEligibleRerouteAt,
            Date(timeIntervalSince1970: 108.0),
            "Next eligible reroute must be anchored to failure completion time (t=106 + 2s = 108s)"
        )

        // Observation at t=107.9 (before completion-based backoff expires) -> No retry
        simulatedNow = Date(timeIntervalSince1970: 107.9)
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: simulatedNow)
        XCTAssertEqual(mockRouting.callCount, 1)

        // Observation at t=108.1 (after completion-based backoff expires) -> Retry triggered!
        simulatedNow = Date(timeIntervalSince1970: 108.1)
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: simulatedNow)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.callCount, 2)
    }

    // MARK: - Test 12 (P2.1): Success Stabilization Begins at Commit Time Not Request Start

    func testSuccessStabilizationBeginsAtCommitTimeNotRequestStart() async {
        simulatedNow = Date(timeIntervalSince1970: 200.0)
        mockRouting.resultToReturn = .success(replacementRoute)
        mockRouting.delayNanoseconds = 50_000_000 // 50ms simulated async latency

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        let decision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .sustainedLateralDeviation,
            lateralDistanceMeters: 25.0,
            activeThresholdMeters: 15.0
        )

        // Request starts at t=200.0
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: simulatedNow)
        XCTAssertTrue(rerouteManager.isRerouting)

        // Advance clock to t=205.0 while routing request is pending
        simulatedNow = Date(timeIntervalSince1970: 205.0)

        // Allow routing success to complete and commit
        try? await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertFalse(rerouteManager.isRerouting)
        // lastCommittedAt MUST be anchored to commit time (205.0), NOT request start (200.0)!
        XCTAssertEqual(
            rerouteManager.lastCommittedAt,
            Date(timeIntervalSince1970: 205.0),
            "lastCommittedAt must be anchored to actual commit time (t=205)"
        )

        // Observation at t=206.0 (within 2s post-success stabilization window) -> Discarded
        simulatedNow = Date(timeIntervalSince1970: 206.0)
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: simulatedNow)
        XCTAssertEqual(mockRouting.callCount, 1)

        // Observation at t=207.5 (after stabilization window expires at t=207.0) -> New reroute eligible!
        simulatedNow = Date(timeIntervalSince1970: 207.5)
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: simulatedNow)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(mockRouting.callCount, 2)
    }

    // MARK: - Test 13 (P2.1): Production Callback Integration Single-Flight Guarantee

    func testProductionCallbackIntegrationSingleFlight() async {
        mockRouting.resultToReturn = .success(replacementRoute)
        mockRouting.delayNanoseconds = 50_000_000

        // Instantiate real NavigationViewModel with injected test dependencies
        let viewModel = NavigationViewModel(
            routingService: mockRouting,
            navSession: navSession
        )

        // Start navigation
        let place = GoongPlace(
            placeID: "dest",
            name: "Goal",
            formattedAddress: "Address",
            location: CLLocation(latitude: 10.005, longitude: 106.0)
        )
        viewModel.selectedDestination = place
        viewModel.startNavigation()

        XCTAssertEqual(viewModel.navSession.state, .navigating)
        XCTAssertEqual(mockRouting.callCount, 0)

        // Create a confirmed off-route decision
        let confirmedDecision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .sustainedLateralDeviation,
            lateralDistanceMeters: 25.0,
            activeThresholdMeters: 15.0
        )
        let smLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.001, longitude: 106.001),
            altitude: 0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            timestamp: baseDate
        )

        // Trigger the session callback through actual NavigationSessionManager pipeline
        navSession.onOffRouteDecision?(confirmedDecision, smLoc)

        // Even if legacy onRerouteNeeded is invoked, it must NOT trigger a second routing request!
        navSession.onRerouteNeeded?()

        try? await Task.sleep(nanoseconds: 20_000_000)

        // Exactly ONE routing request must have been dispatched!
        XCTAssertEqual(mockRouting.callCount, 1, "Must execute exactly ONE routing call (no duplicate trigger from onRerouteNeeded)")

        // Complete request
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(viewModel.rerouteManager.isRerouting)
        viewModel.stopNavigation()
    }

    // MARK: - Test 14 (P2.1): Transport Supersession Does Not Count As Failure

    func testTransportSupersessionDoesNotCountAsFailure() async {
        mockRouting.delayNanoseconds = 100_000_000 // 100ms
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

        // Off-route request A begins
        rerouteManager.startReroute(reason: .offRoute, origin: loc.coordinate, costing: "motorcycle")
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(rerouteManager.isRerouting)
        XCTAssertEqual(rerouteManager.currentReason, .offRoute)
        XCTAssertEqual(mockRouting.callCount, 1)

        // User changes transport mode to auto while request A is in flight -> Supersedes A
        rerouteManager.requestTransportModeReroute(costing: "auto", origin: loc.coordinate)
        XCTAssertEqual(rerouteManager.currentReason, .transportModeChanged)
        XCTAssertEqual(mockRouting.callCount, 2)

        // Wait for request A and request B to settle
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Verification:
        XCTAssertEqual(rerouteManager.failureCount, 0, "Superseded request A must not increment failureCount")
        XCTAssertNil(rerouteManager.nextEligibleRerouteAt, "Superseded request A must not schedule backoff")
        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertEqual(mockRouting.lastCosting, "auto", "Request B was authoritative")
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 500.0, "Route B successfully committed")
    }

    // MARK: - Test 15 (P2.1): Cancel Does Not Record Failure After Unwind

    func testCancelDoesNotRecordFailureAfterUnwind() async {
        mockRouting.delayNanoseconds = 100_000_000 // 100ms
        mockRouting.resultToReturn = .success(replacementRoute)

        let loc = CLLocation(latitude: 10.001, longitude: 106.001)
        rerouteManager.startReroute(reason: .offRoute, origin: loc.coordinate, costing: "motorcycle")
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(rerouteManager.isRerouting)

        // Explicit cancel
        rerouteManager.cancel()
        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertNil(rerouteManager.currentReason)

        // Allow cancelled async task to unwind completely
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Must remain clean:
        XCTAssertEqual(rerouteManager.failureCount, 0, "Explicit cancel must not count as failure")
        XCTAssertNil(rerouteManager.nextEligibleRerouteAt, "Explicit cancel must not set backoff")
        XCTAssertFalse(rerouteManager.isRerouting)
        XCTAssertNil(rerouteManager.currentReason)
    }
}
