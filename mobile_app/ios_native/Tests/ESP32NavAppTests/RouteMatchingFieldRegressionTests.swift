//
//  RouteMatchingFieldRegressionTests.swift
//  Field regression tests for confidence-based route matching, sharp turns, parallel roads, and stuck recovery.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

@MainActor
final class RouteMatchingFieldRegressionTests: XCTestCase {

    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    // MARK: - Test 1: Pure Nearest-Distance Query (Requirement 11)

    func testPureNearestProjection_HasNoContinuityBias() {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.810),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.820),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.830)
        ]
        let geometry = RouteGeometry(coordinates: coords)

        let queryPoint = CLLocationCoordinate2D(latitude: 21.0001, longitude: 105.825)
        let nearest = geometry.nearestProjection(to: queryPoint)

        XCTAssertNotNil(nearest)
        XCTAssertEqual(nearest?.segmentIndex, 2)
        XCTAssertEqual(nearest?.lateralDistanceMeters ?? 0.0, 11.13, accuracy: 1.0)
    }

    // MARK: - Test 2: Sharp 90-Degree Turn (Requirement 19 & 44)

    func testSharp90DegreeTurn_TransitionsPromptlyWithoutLag() {
        let startCoord = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let turnCoord  = CLLocationCoordinate2D(latitude: 21.0006, longitude: 105.800) // ~67m north
        let endCoord   = CLLocationCoordinate2D(latitude: 21.0006, longitude: 105.8008) // ~83m east

        let coords = [startCoord, turnCoord, endCoord]
        let step0 = NavStep(
            coordinate: startCoord,
            distanceMeters: 67.0,
            durationSeconds: 7.0,
            streetName: "Phố Huế",
            maneuverType: .straight,
            instruction: "Đi thẳng trên Phố Huế",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        let step1 = NavStep(
            coordinate: turnCoord,
            distanceMeters: 83.0,
            durationSeconds: 8.0,
            streetName: "Đại Cồ Việt",
            maneuverType: .right,
            instruction: "Rẽ phải vào Đại Cồ Việt",
            beginShapeIndex: 1,
            endShapeIndex: 2
        )
        let step2 = NavStep(
            coordinate: endCoord,
            distanceMeters: 0.0,
            durationSeconds: 0.0,
            streetName: "Đại Cồ Việt",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 2,
            endShapeIndex: 2
        )

        let route = NavRoute(coordinates: coords, steps: [step0, step1, step2], totalDistanceMeters: 150.0, totalDurationSeconds: 15.0)
        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: endCoord, name: "Đích"))

        var currentTime = baseDate
        // 1. Five samples heading North towards the turn (~10m per frame at 10 m/s)
        for i in 1...5 {
            let lat = 21.000 + Double(i) * 0.00009
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 105.800),
                altitude: 10.0,
                horizontalAccuracy: 4.0,
                verticalAccuracy: 4.0,
                course: 0.0,
                speed: 10.0,
                timestamp: currentTime
            )
            session.ingestLocation(loc)
            currentTime = currentTime.addingTimeInterval(1.0)

            XCTAssertEqual(session.currentPolylineSegmentIndex, 0, "Must be on northbound segment")
            XCTAssertEqual(session.currentManeuverStepIndex, 1, "Upcoming maneuver must be step 1 (turn right)")
        }

        // 2. Immediate sharp turn onto eastbound street (5 samples heading East)
        for j in 1...5 {
            let lon = 105.800 + Double(j) * 0.00009
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 21.0006, longitude: lon),
                altitude: 10.0,
                horizontalAccuracy: 4.0,
                verticalAccuracy: 4.0,
                course: 90.0,
                speed: 9.0,
                timestamp: currentTime
            )
            session.ingestLocation(loc)
            currentTime = currentTime.addingTimeInterval(1.0)
        }

        XCTAssertEqual(session.currentPolylineSegmentIndex, 1, "Matcher must have transitioned to eastbound segment")
        XCTAssertEqual(session.currentManeuverStepIndex, 2, "Must advance to step 2 after passing turn")
        XCTAssertTrue(session.remainingPolyline.count <= 2, "Northbound coordinates must be completely trimmed from remainingPolyline")
        XCTAssertFalse(session.isOffRoute, "Vehicle followed the turn onto Route, must NOT be confirmed off-route")
    }

    // MARK: - Test 3: Close Parallel Roads (Requirements 8-14, 35)

    func testCloseParallelRoads_DetectsPhysicalSeparationAndTriggersReroute() async {
        let coordsA = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.8000),
            CLLocationCoordinate2D(latitude: 21.005, longitude: 105.8000)
        ]
        let step = NavStep(
            coordinate: coordsA[1],
            distanceMeters: 556.0,
            durationSeconds: 60.0,
            streetName: "Đường chính",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        let route = NavRoute(coordinates: coordsA, steps: [step], totalDistanceMeters: 556.0, totalDurationSeconds: 60.0)

        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        let routingService = ParallelTestRecordingRoutingService()
        var time = baseDate
        let rerouteManager = RerouteManager(
            routingService: routingService,
            navSession: session,
            now: { time }
        )
        session.onOffRouteDecision = { decision, loc in
            rerouteManager.handleObservation(location: loc, decision: decision, currentTime: time)
        }

        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coordsA[1], name: "Đích"))

        // Vehicle drives on parallel service road: ~12.5m east (lon 105.80012)
        // Same course (0.0° north), speed 8.5 m/s, GPS accuracy 4.0m
        // Ingest sample 1 at t=0
        let loc1 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0014, longitude: 105.80012),
            altitude: 10.0,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            course: 0.0,
            speed: 8.5,
            timestamp: time
        )
        session.ingestLocation(loc1)

        // Moderate deviation threshold with 4m accuracy: max(10.0, 4.0 * 1.5) = 10.0m <= 12.5m
        // First sample becomes suspected with persistentModerateLateralDeviation
        XCTAssertEqual(session.offRouteState, .suspected)
        XCTAssertEqual(session.offRouteDecision?.reason, .persistentModerateLateralDeviation)
        XCTAssertFalse(session.isOffRoute)
        XCTAssertEqual(session.diagnostics.rerouteRequests, 0)

        // Sample 2 at t = 1.0s (dwell 1.0s < moderateDeviationDwell 2.0s) -> remains suspected
        time = time.addingTimeInterval(1.0)
        let loc2 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0022, longitude: 105.80012),
            altitude: 10.0,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            course: 0.0,
            speed: 8.5,
            timestamp: time
        )
        session.ingestLocation(loc2)
        XCTAssertEqual(session.offRouteState, .suspected)
        XCTAssertFalse(session.isOffRoute)
        XCTAssertEqual(session.diagnostics.rerouteRequests, 0)

        // Sample 3 at t = 2.1s (elapsed 2.1s >= 2.0s dwell) -> confirms off-route!
        time = time.addingTimeInterval(1.1)
        let loc3 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0030, longitude: 105.80012),
            altitude: 10.0,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            course: 0.0,
            speed: 8.5,
            timestamp: time
        )
        session.ingestLocation(loc3)

        // Asserts:
        // 1. Confirmed off-route within bounded latency (~2.1s)
        XCTAssertEqual(session.offRouteState, .confirmed)
        XCTAssertTrue(session.isOffRoute)
        XCTAssertEqual(session.offRouteDecision?.reason, .persistentModerateLateralDeviation)

        // 2. Exactly one reroute request starts
        XCTAssertEqual(session.diagnostics.rerouteRequests, 1)
        XCTAssertTrue(rerouteManager.isRerouting)

        // Wait for async task to record routing origin
        for _ in 0..<30 {
            if routingService.lastOrigin != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // 3. Reroute origin equals latest acceptedPhysicalLocation
        XCTAssertNotNil(routingService.lastOrigin)
        XCTAssertEqual(routingService.lastOrigin?.latitude ?? 0, loc3.coordinate.latitude, accuracy: 1e-5)
        XCTAssertEqual(routingService.lastOrigin?.longitude ?? 0, loc3.coordinate.longitude, accuracy: 1e-5)
        XCTAssertEqual(session.acceptedPhysicalLocation?.coordinate.latitude ?? 0, loc3.coordinate.latitude, accuracy: 1e-5)

        // 4. Single-flight behavior: feeding another observation while rerouting does not launch duplicate request
        time = time.addingTimeInterval(0.5)
        let loc4 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0034, longitude: 105.80012),
            altitude: 10.0,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            course: 0.0,
            speed: 8.5,
            timestamp: time
        )
        session.ingestLocation(loc4)
        XCTAssertEqual(session.diagnostics.rerouteRequests, 1, "Single-flight guard must prevent duplicate reroute request")
    }

    func testCloseParallelRoads_PoorGPS_DoesNotInstantlyConfirmOffRoute() {
        let coordsA = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.8000),
            CLLocationCoordinate2D(latitude: 21.005, longitude: 105.8000)
        ]
        let step = NavStep(
            coordinate: coordsA[1],
            distanceMeters: 556.0,
            durationSeconds: 60.0,
            streetName: "Đường chính",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        let route = NavRoute(coordinates: coordsA, steps: [step], totalDistanceMeters: 556.0, totalDurationSeconds: 60.0)

        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coordsA[1], name: "Đích"))

        var time = baseDate

        // Same 12.5m separation, but horizontalAccuracy = 14.0m
        // moderateThreshold = max(10.0, 14.0 * 1.5) = 21.0m > 12.5m
        // enterThreshold = max(15.0, 14.0 * 1.2) = 16.8m > 12.5m
        // Vehicle must remain onRoute!
        for i in 1...4 {
            let lat = 21.001 + Double(i) * 0.0008
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 105.80012),
                altitude: 10.0,
                horizontalAccuracy: 14.0,
                verticalAccuracy: 4.0,
                course: 0.0,
                speed: 8.5,
                timestamp: time
            )
            session.ingestLocation(loc)
            time = time.addingTimeInterval(1.0)
        }

        XCTAssertEqual(session.offRouteState, .onRoute, "Poor GPS accuracy (14m) scales thresholds and prevents premature off-route confirmation")
        XCTAssertFalse(session.isOffRoute)
    }

    // MARK: - Test 4: Bridge / Underpass Self-Near Geometry (Requirement 46)

    func testBridgeUnderpassSelfNear_DoesNotJumpPrematurelyOrLock() {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.8000),
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.8000),
            CLLocationCoordinate2D(latitude: 21.003, longitude: 105.8030),
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.8001),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.8001)
        ]
        let geometry = RouteGeometry(coordinates: coords)

        let lowerGPS = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0018, longitude: 105.8000),
            altitude: 5.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 10.0,
            timestamp: baseDate
        )

        let match1 = geometry.matchLocation(location: lowerGPS)
        XCTAssertNotNil(match1)
        XCTAssertEqual(match1?.projection.segmentIndex, 0, "Must match lower road, NOT elevated bridge")

        let lowerGPS2 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0019, longitude: 105.8000),
            altitude: 5.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 10.0,
            timestamp: baseDate.addingTimeInterval(1.0)
        )
        let match2 = geometry.matchLocation(
            location: lowerGPS2,
            lastProjection: match1?.projection,
            lastMatchedTimestamp: baseDate
        )
        XCTAssertEqual(match2?.projection.segmentIndex, 0, "Must stay on lower road, NOT jump to elevated bridge")
    }

    // MARK: - Test 5: Stuck Matcher Recovery (Requirement 12, 13, 14)

    func testStuckMatcherRecovery_TriggersControlledForwardJump() {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.810),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.820),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.830),
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.840)
        ]
        let geometry = RouteGeometry(coordinates: coords)

        let stuckProjection = RouteProjection(
            coordinate: coords[0],
            segmentIndex: 0,
            segmentFraction: 0.1,
            lateralDistanceMeters: 5.0,
            distanceAlongRouteMeters: 100.0
        )

        let vehicleLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.00005, longitude: 105.825),
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 90.0,
            speed: 12.0,
            timestamp: baseDate.addingTimeInterval(2.0)
        )

        let result = geometry.matchLocation(
            location: vehicleLocation,
            lastProjection: stuckProjection,
            lastMatchedTimestamp: baseDate,
            stuckRecoveryTriggered: true
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.usedGlobalRecovery, "Must use global recovery when stuckRecoveryTriggered")
        XCTAssertEqual(result!.projection.segmentIndex, 2, "Must jump forward to segment 2 where vehicle physically is")
        XCTAssertEqual(result!.confidence, .high)
    }

    // MARK: - Test 6: Continuous Polyline Trimming Regression (Requirement 18 & 55)

    func testContinuousPolylineTrimming_TrimsPromptlyWithoutReroute() {
        var coords: [CLLocationCoordinate2D] = []
        // Spaced ~11 meters apart (~0.0001 deg latitude), perfectly matching 1-second GPS updates at 10 m/s
        for i in 0..<10 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000 + Double(i) * 0.0001, longitude: 105.800))
        }
        let step = NavStep(
            coordinate: coords.last!,
            distanceMeters: 100.0,
            durationSeconds: 10.0,
            streetName: "Đường thẳng",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 9
        )
        let route = NavRoute(coordinates: coords, steps: [step], totalDistanceMeters: 100.0, totalDurationSeconds: 10.0)

        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coords.last!, name: "Đích"))

        XCTAssertEqual(session.remainingPolyline.count, 10, "Initial polyline must have all 10 points")

        var time = baseDate
        var previousRemainingCount = session.remainingPolyline.count
        var previousDisplayProgress = session.displayProgressDistanceAlongRoute

        for ptIdx in 1...5 {
            let loc = CLLocation(
                coordinate: coords[ptIdx],
                altitude: 10.0,
                horizontalAccuracy: 4.0,
                verticalAccuracy: 4.0,
                course: 0.0,
                speed: 10.0,
                timestamp: time
            )
            session.ingestLocation(loc)
            time = time.addingTimeInterval(1.0)

            XCTAssertGreaterThan(session.displayProgressDistanceAlongRoute, previousDisplayProgress,
                                 "Progress must advance at step \(ptIdx)")
            previousDisplayProgress = session.displayProgressDistanceAlongRoute

            XCTAssertLessThanOrEqual(session.remainingPolyline.count, previousRemainingCount,
                                     "Polyline count must not increase as vehicle drives forward")
            previousRemainingCount = session.remainingPolyline.count

            XCTAssertEqual(session.diagnostics.rerouteRequests, 0, "No reroute request must occur for normal driving")
            XCTAssertFalse(session.isRerouting)
        }

        XCTAssertLessThanOrEqual(session.remainingPolyline.count, 6)
    }
}


private final class ParallelTestRecordingRoutingService: RoutingServiceProtocol, @unchecked Sendable {
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
