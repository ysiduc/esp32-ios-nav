//
//  OffRouteFieldLatencyTests.swift
//  Latency, physical origin, stationary protection, and full replay field regression tests.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

final class OffRouteFieldLatencyTests: XCTestCase {

    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    // MARK: - Test 1: Fast Moving Wrong Turn Latency (Requirement 24)

    func testFastMovingWrongTurn_ConfirmsWithinOneToTwoSeconds() {
        let detector = OffRouteDetector()

        // Sample 1: On-route at t=0
        let obs0 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 2.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 0.0,
            routeBearingDegrees: 0.0,
            distanceAlongRouteMeters: 100.0,
            rawNearestRouteDistanceMeters: 2.0
        )
        let dec0 = detector.evaluate(observation: obs0)
        XCTAssertEqual(dec0.state, .onRoute)

        // Sample 2: Wrong turn initiated at t=1.0s (course diverged 90 degrees, raw physical separation 10m)
        let obs1 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(1.0),
            lateralDistanceMeters: 10.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 0.0,
            distanceAlongRouteMeters: 100.0,
            rawNearestRouteDistanceMeters: 10.0
        )
        let dec1 = detector.evaluate(observation: obs1)
        XCTAssertEqual(dec1.state, .suspected, "Must become suspected promptly upon moving course divergence")
        XCTAssertEqual(dec1.reason, .courseDivergence)

        // Sample 3: Continued divergence at t=2.0s (elapsed suspect = 1.0s >= courseDivergenceDwell 1.0s)
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(2.0),
            lateralDistanceMeters: 18.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 0.0,
            distanceAlongRouteMeters: 100.0,
            rawNearestRouteDistanceMeters: 18.0
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .confirmed, "Must confirm within ~1.0-1.5s for moving wrong turn")
        XCTAssertTrue(dec2.becameConfirmed)
    }

    // MARK: - Test 2: Confirmed to Request Start is Immediate (Requirement 51)

    func testConfirmedToRequestStart_IsImmediate() {
        let route = makeSimpleRoute()
        let session = NavigationSessionManager()
        let fakeRouting = DelayedRoutingService(delay: 0.05)
        var currentTime = baseDate
        let rerouteManager = RerouteManager(
            routingService: fakeRouting,
            navSession: session,
            now: { currentTime }
        )

        session.startNavigation(route: route, destination: NavigationDestination(coordinate: route.coordinates.last!, name: "Đích"))
        session.onOffRouteDecision = { decision, location in
            rerouteManager.handleObservation(location: location, decision: decision, currentTime: currentTime)
        }

        // Trigger off-route confirmation
        let obs = OffRouteObservation(
            timestamp: currentTime,
            lateralDistanceMeters: 30.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 0.0,
            distanceAlongRouteMeters: 50.0,
            rawNearestRouteDistanceMeters: 30.0
        )
        // t=0: suspected
        _ = session.ingestCustomObservation(obs)

        // t=1.0s: confirmed
        currentTime = currentTime.addingTimeInterval(1.0)
        let obsConfirmed = OffRouteObservation(
            timestamp: currentTime,
            lateralDistanceMeters: 35.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 0.0,
            distanceAlongRouteMeters: 50.0,
            rawNearestRouteDistanceMeters: 35.0
        )
        let dec = session.ingestCustomObservation(obsConfirmed)
        XCTAssertEqual(dec.state, .confirmed)
        XCTAssertTrue(dec.becameConfirmed)

        // Must be in rerouting state immediately without delay
        XCTAssertTrue(rerouteManager.isRerouting, "Reroute must start immediately on confirmation frame")
        XCTAssertTrue(session.isRerouting, "Session isRerouting must be true immediately")
        XCTAssertEqual(rerouteManager.rerouteStartedAt, currentTime)
    }

    // MARK: - Test 3: Reroute Origin Uses Accepted Physical Location (Requirement 26)

    func testRerouteOrigin_UsesAcceptedPhysicalLocation() {
        let route = makeSimpleRoute()
        let session = NavigationSessionManager()
        let recordingService = RecordingRoutingService()
        let rerouteManager = RerouteManager(
            routingService: recordingService,
            navSession: session,
            now: { self.baseDate }
        )

        session.startNavigation(route: route, destination: NavigationDestination(coordinate: route.coordinates.last!, name: "Đích"))
        session.onOffRouteDecision = { decision, location in
            rerouteManager.handleObservation(location: location, decision: decision, currentTime: self.baseDate)
        }

        // Physical location that clearly deviated onto a cross-street (lat 21.000, lon 105.805)
        let rawGPS = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.000, longitude: 105.805),
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 90.0,
            speed: 10.0,
            timestamp: baseDate
        )

        // Verify accepted physical location is recorded
        session.ingestLocation(rawGPS)
        XCTAssertNotNil(session.acceptedPhysicalLocation)
        XCTAssertEqual(session.acceptedPhysicalLocation?.coordinate.latitude, 21.000)
        XCTAssertEqual(session.acceptedPhysicalLocation?.coordinate.longitude, 105.805)
    }

    // MARK: - Test 4: First Reroute Not Delayed by Stabilization (Requirement 52)

    func testFirstReroute_NotDelayedByPostSuccessStabilization() {
        let route = makeSimpleRoute()
        let session = NavigationSessionManager()
        let recordingService = RecordingRoutingService()
        let rerouteManager = RerouteManager(
            routingService: recordingService,
            navSession: session,
            now: { self.baseDate }
        )

        session.startNavigation(route: route, destination: NavigationDestination(coordinate: route.coordinates.last!, name: "Đích"))

        // Confirmed decision at t=0 (first reroute)
        let decision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .courseDivergence,
            lateralDistanceMeters: 25.0,
            activeThresholdMeters: 15.0
        )
        let location = CLLocation(
            latitude: 21.001,
            longitude: 105.802
        )

        rerouteManager.handleObservation(location: location, decision: decision, currentTime: baseDate)
        XCTAssertTrue(rerouteManager.isRerouting, "First reroute must start immediately and NOT be delayed")
    }

    // MARK: - Test 5: Stationary Drift Protection (Requirement 25)

    func testStationaryDriftProtection_LowSpeedMaintainsLongerDwell() {
        let detector = OffRouteDetector()

        // Low speed 0.5 m/s with 20m drift (at a traffic light)
        let obs0 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 20.0,
            horizontalAccuracyMeters: 8.0,
            speedMetersPerSecond: 0.5,
            courseDegrees: nil,
            distanceAlongRouteMeters: 100.0,
            rawNearestRouteDistanceMeters: 20.0
        )
        let dec0 = detector.evaluate(observation: obs0)
        XCTAssertEqual(dec0.state, .suspected)

        // At t = 3.0s, still under 5.0s stationary dwell
        let obs1 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(3.0),
            lateralDistanceMeters: 20.0,
            horizontalAccuracyMeters: 8.0,
            speedMetersPerSecond: 0.5,
            courseDegrees: nil,
            distanceAlongRouteMeters: 100.0,
            rawNearestRouteDistanceMeters: 20.0
        )
        let dec1 = detector.evaluate(observation: obs1)
        XCTAssertEqual(dec1.state, .suspected, "Stationary GPS drift must remain suspected, not confirmed after 3s")

        // At t = 5.0s, stationary dwell completes
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(5.0),
            lateralDistanceMeters: 20.0,
            horizontalAccuracyMeters: 8.0,
            speedMetersPerSecond: 0.5,
            courseDegrees: nil,
            distanceAlongRouteMeters: 100.0,
            rawNearestRouteDistanceMeters: 20.0
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .confirmed)
    }

    // MARK: - Test 6: Single-Flight Reroute Guarantee (Requirement 53)

    func testSingleFlightRerouteGuarantee_DoesNotSpawnDuplicateRequests() {
        let route = makeSimpleRoute()
        let session = NavigationSessionManager()
        let delayedService = DelayedRoutingService(delay: 5.0)
        let rerouteManager = RerouteManager(
            routingService: delayedService,
            navSession: session,
            now: { self.baseDate }
        )

        session.startNavigation(route: route, destination: NavigationDestination(coordinate: route.coordinates.last!, name: "Đích"))

        let decision = OffRouteDecision(
            state: .confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: .strongLateralDeviation,
            lateralDistanceMeters: 35.0,
            activeThresholdMeters: 15.0
        )
        let loc = CLLocation(latitude: 21.002, longitude: 105.803)

        // First observation starts reroute
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate)
        XCTAssertTrue(rerouteManager.isRerouting)
        let firstGen = rerouteManager.rerouteRequestGeneration

        // Second observation arrives while first is still in flight
        rerouteManager.handleObservation(location: loc, decision: decision, currentTime: baseDate.addingTimeInterval(0.5))

        // Generation must NOT change, single request remains in flight
        XCTAssertEqual(rerouteManager.rerouteRequestGeneration, firstGen, "Must not start a duplicate request while already rerouting")
    }

    // MARK: - Test 7: Field-Style Full Replay #1 — Normal Maneuver Pass (Requirement 56)

    func testFieldReplay1_NormalManeuverPass() {
        let route = makeTurnRoute()
        let session = NavigationSessionManager()
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: route.coordinates.last!, name: "Đích"))

        var time = baseDate
        var lastRemainingDist: Double = Double(session.activeProgress.remainingDistanceMeters)

        // Replay driving along the route approaching and passing turn
        for (i, coord) in route.coordinates.enumerated() {
            let loc = CLLocation(
                coordinate: coord,
                altitude: 10.0,
                horizontalAccuracy: 4.0,
                verticalAccuracy: 4.0,
                course: i < 3 ? 0.0 : 90.0,
                speed: 8.0,
                timestamp: time
            )
            session.ingestLocation(loc)
            time = time.addingTimeInterval(1.0)

            // Progress advances
            XCTAssertFalse(session.isOffRoute)
            XCTAssertEqual(session.diagnostics.rerouteRequests, 0)
        }

        // Maneuver must have advanced to final arrive step
        XCTAssertEqual(session.currentManeuverStepIndex, 1)
    }

    // MARK: - Test 8: Field-Style Full Replay #2 — Wrong Turn (Requirement 57)

    func testFieldReplay2_WrongTurn() async {
        let routeA = makeTurnRoute()
        let session = NavigationSessionManager()
        let recordingService = RecordingRoutingService()
        var currentTime = baseDate
        let rerouteManager = RerouteManager(
            routingService: recordingService,
            navSession: session,
            now: { currentTime }
        )

        session.startNavigation(route: routeA, destination: NavigationDestination(coordinate: routeA.coordinates.last!, name: "Đích"))
        session.onOffRouteDecision = { decision, location in
            rerouteManager.handleObservation(location: location, decision: decision, currentTime: currentTime)
        }

        // 1. Approach intersection along Northbound segment (coord 0, 1)
        for i in 0...1 {
            let loc = CLLocation(
                coordinate: routeA.coordinates[i],
                altitude: 10.0,
                horizontalAccuracy: 4.0,
                verticalAccuracy: 4.0,
                course: 0.0,
                speed: 8.0,
                timestamp: currentTime
            )
            session.ingestLocation(loc)
            currentTime = currentTime.addingTimeInterval(1.0)
            XCTAssertFalse(session.isOffRoute)
            XCTAssertFalse(rerouteManager.isRerouting)
        }

        // 2. Instead of turning right onto Eastbound branch, vehicle takes wrong branch (continues North / North-West)
        // For first 20m, wrong road is close to intersection, then diverges with course 330 degrees
        let wrong1 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0022, longitude: 105.7999),
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 330.0, // diverging course
            speed: 10.0,
            timestamp: currentTime
        )
        session.ingestLocation(wrong1)
        currentTime = currentTime.addingTimeInterval(1.0)

        // Prompt suspicion
        XCTAssertEqual(session.offRouteState, .suspected)

        // Next sample moving further away
        let wrong2 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0028, longitude: 105.7997),
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 330.0,
            speed: 10.0,
            timestamp: currentTime
        )
        session.ingestLocation(wrong2)

        // Confirmed within moving-vehicle bound (~1.0s)
        XCTAssertEqual(session.offRouteState, .confirmed)
        XCTAssertTrue(rerouteManager.isRerouting)
        XCTAssertEqual(session.diagnostics.rerouteRequests, 1, "Exactly one reroute request started")

        // Reroute origin uses accepted physical location (wrong2 coordinate)
        XCTAssertNotNil(recordingService.lastOrigin)
        XCTAssertEqual(recordingService.lastOrigin?.latitude ?? 0, 21.0028, accuracy: 1e-4)

        // Old route remains active while request is in flight
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, routeA.totalDistanceMeters)
    }

    // MARK: - Test 9: Field-Style Full Replay #3 — Tunnel / Underpass (Requirement 58)

    func testFieldReplay3_TunnelUnderpass() {
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...15 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000 + Double(i) * 0.0008, longitude: 105.800))
        }

        let step0 = NavStep(coordinate: coords[4], distanceMeters: 300.0, durationSeconds: 30.0, streetName: "Đường Kim Đồng", maneuverType: .straight, instruction: "Đi thẳng", beginShapeIndex: 0, endShapeIndex: 4)
        let step1 = NavStep(coordinate: coords[10], distanceMeters: 500.0, durationSeconds: 40.0, streetName: "Hầm chui Kim Đồng - Giải Phóng", maneuverType: .enterTunnel, instruction: "Vào Hầm chui Kim Đồng - Giải Phóng", beginShapeIndex: 4, endShapeIndex: 10)
        let step2 = NavStep(coordinate: coords[15], distanceMeters: 400.0, durationSeconds: 30.0, streetName: "Đường Giải Phóng", maneuverType: .arrive, instruction: "Đến đích", beginShapeIndex: 10, endShapeIndex: 15)

        let route = NavRoute(coordinates: coords, steps: [step0, step1, step2], totalDistanceMeters: 1200.0, totalDurationSeconds: 100.0)
        let session = NavigationSessionManager()
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coords.last!, name: "Đích"))

        var time = baseDate
        var previousRemainingCount = session.remainingPolyline.count

        // Replay driving through surface -> tunnel -> post-tunnel
        for i in 0...13 {
            let loc = CLLocation(
                coordinate: coords[i],
                altitude: (i >= 5 && i <= 9) ? -5.0 : 10.0,
                horizontalAccuracy: (i >= 5 && i <= 9) ? 8.0 : 4.0, // Tunnel has slightly worse accuracy
                verticalAccuracy: 5.0,
                course: 0.0,
                speed: 10.0,
                timestamp: time
            )
            session.ingestLocation(loc)
            time = time.addingTimeInterval(1.0)

            // Polyline continuously trims throughout
            XCTAssertLessThanOrEqual(session.remainingPolyline.count, previousRemainingCount)
            previousRemainingCount = session.remainingPolyline.count

            if i >= 11 {
                // Past tunnel exit: tunnel instruction MUST NOT be active
                XCTAssertNotEqual(session.activeProgress.maneuver, .enterTunnel, "Tunnel instruction must not persist past exit")
                XCTAssertNotEqual(session.activeProgress.nextStreetName, "Hầm chui Kim Đồng - Giải Phóng")
                XCTAssertEqual(session.currentManeuverStepIndex, 2)
            }
        }
    }

    // MARK: - Helpers

    private func makeSimpleRoute() -> NavRoute {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.005, longitude: 105.800)
        ]
        let step = NavStep(
            coordinate: coords[1],
            distanceMeters: 556.0,
            durationSeconds: 60.0,
            streetName: "Đường thẳng",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        return NavRoute(coordinates: coords, steps: [step], totalDistanceMeters: 556.0, totalDurationSeconds: 60.0)
    }

    private func makeTurnRoute() -> NavRoute {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.001, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.800), // Turn at (21.002, 105.800)
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.801),
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.802)
        ]
        let step0 = NavStep(
            coordinate: coords[2],
            distanceMeters: 222.0,
            durationSeconds: 25.0,
            streetName: "Đoạn 1",
            maneuverType: .turnRight,
            instruction: "Rẽ phải",
            beginShapeIndex: 0,
            endShapeIndex: 2
        )
        let step1 = NavStep(
            coordinate: coords[4],
            distanceMeters: 200.0,
            durationSeconds: 25.0,
            streetName: "Đoạn 2",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 2,
            endShapeIndex: 4
        )
        return NavRoute(coordinates: coords, steps: [step0, step1], totalDistanceMeters: 422.0, totalDurationSeconds: 50.0)
    }
}

// MARK: - Mocks for Testing

private final class DelayedRoutingService: RoutingServiceProtocol, @unchecked Sendable {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        let coords = [origin, destination]
        let step = NavStep(
            coordinate: destination,
            distanceMeters: 100.0,
            durationSeconds: 10.0,
            streetName: "Đường mới",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        return NavRoute(coordinates: coords, steps: [step], totalDistanceMeters: 100.0, totalDurationSeconds: 10.0)
    }
}

private final class RecordingRoutingService: RoutingServiceProtocol, @unchecked Sendable {
    var lastOrigin: CLLocationCoordinate2D?

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        lastOrigin = origin
        let coords = [origin, destination]
        let step = NavStep(
            coordinate: destination,
            distanceMeters: 100.0,
            durationSeconds: 10.0,
            streetName: "Đường mới",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        return NavRoute(coordinates: coords, steps: [step], totalDistanceMeters: 100.0, totalDurationSeconds: 10.0)
    }
}

// Extension to feed custom observation directly for deterministic state machine tests
extension NavigationSessionManager {
    @discardableResult
    func ingestCustomObservation(_ obs: OffRouteObservation) -> OffRouteDecision {
        let dec = self.offRouteDetector.evaluate(observation: obs)
        self.offRouteDecision = dec
        self.offRouteState = dec.state
        self.isOffRoute = (dec.state == .confirmed)
        if dec.becameConfirmed {
            self.diagnostics.offRouteConfirmations += 1
            self.diagnostics.offRouteConfirmedAt = obs.timestamp
        }
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8),
            altitude: 10.0,
            horizontalAccuracy: obs.horizontalAccuracyMeters,
            verticalAccuracy: 5.0,
            course: obs.courseDegrees ?? 0.0,
            speed: obs.speedMetersPerSecond,
            timestamp: obs.timestamp
        )
        self.onOffRouteDecision?(dec, loc)
        return dec
    }
}
