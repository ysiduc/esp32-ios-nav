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
        let turnCoord = CLLocationCoordinate2D(latitude: 21.003, longitude: 105.800)
        let endCoord = CLLocationCoordinate2D(latitude: 21.003, longitude: 105.804)
        let startCoord = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)

        let coords = [startCoord, turnCoord, endCoord]
        let step0 = NavStep(
            coordinate: turnCoord,
            distanceMeters: 333.0,
            durationSeconds: 30.0,
            streetName: "Phố Huế",
            maneuverType: .right,
            instruction: "Rẽ phải vào Đại Cồ Việt",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        let step1 = NavStep(
            coordinate: endCoord,
            distanceMeters: 416.0,
            durationSeconds: 40.0,
            streetName: "Đại Cồ Việt",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 1,
            endShapeIndex: 2
        )

        let route = NavRoute(coordinates: coords, steps: [step0, step1], totalDistanceMeters: 749.0, totalDurationSeconds: 70.0)
        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: endCoord, name: "Đích"))

        var currentTime = baseDate
        for i in 1...5 {
            let lat = 21.000 + Double(i) * 0.0005
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 105.800),
                altitude: 10.0,
                horizontalAccuracy: 5.0,
                verticalAccuracy: 5.0,
                course: 0.0,
                speed: 10.0,
                timestamp: currentTime
            )
            session.ingestLocation(loc)
            currentTime = currentTime.addingTimeInterval(1.0)

            XCTAssertEqual(session.currentPolylineSegmentIndex, 0, "Must be on northbound segment")
            XCTAssertEqual(session.currentManeuverStepIndex, 0, "Upcoming maneuver must be step 0 (turn right)")
        }

        for j in 1...5 {
            let lon = 105.800 + Double(j) * 0.0006
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 21.003, longitude: lon),
                altitude: 10.0,
                horizontalAccuracy: 6.0,
                verticalAccuracy: 5.0,
                course: 90.0,
                speed: 9.0,
                timestamp: currentTime
            )
            session.ingestLocation(loc)
            currentTime = currentTime.addingTimeInterval(1.0)
        }

        XCTAssertEqual(session.currentPolylineSegmentIndex, 1, "Matcher must have transitioned to eastbound segment")
        XCTAssertEqual(session.currentManeuverStepIndex, 1, "Must advance to step 1 after passing turn")
        XCTAssertTrue(session.remainingPolyline.count <= 2, "Northbound coordinates must be completely trimmed from remainingPolyline")
        XCTAssertFalse(session.isOffRoute, "Vehicle followed the turn onto Route, must NOT be confirmed off-route")
    }

    // MARK: - Test 3: Close Parallel Roads (Requirement 20 & 45)

    func testCloseParallelRoads_DetectsPhysicalSeparationWithoutStaleSnap() {
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

        for i in 1...6 {
            let lat = 21.001 + Double(i) * 0.0004
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 105.80012),
                altitude: 10.0,
                horizontalAccuracy: 4.0,
                verticalAccuracy: 4.0,
                course: 0.0,
                speed: 8.0,
                timestamp: time
            )
            session.ingestLocation(loc)
            time = time.addingTimeInterval(1.0)
        }

        let rawNearest = route.geometry.nearestProjection(to: CLLocationCoordinate2D(latitude: 21.003, longitude: 105.80012))
        XCTAssertNotNil(rawNearest)
        XCTAssertEqual(rawNearest!.lateralDistanceMeters, 12.5, accuracy: 2.0)

        XCTAssertNotNil(session.acceptedPhysicalLocation)
        XCTAssertEqual(session.acceptedPhysicalLocation?.coordinate.longitude ?? 0, 105.80012, accuracy: 1e-5)
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
        for i in 0..<10 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000 + Double(i) * 0.001, longitude: 105.800))
        }
        let step = NavStep(
            coordinate: coords.last!,
            distanceMeters: 1000.0,
            durationSeconds: 100.0,
            streetName: "Đường thẳng",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 0,
            endShapeIndex: 9
        )
        let route = NavRoute(coordinates: coords, steps: [step], totalDistanceMeters: 1000.0, totalDurationSeconds: 100.0)

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
                horizontalAccuracy: 5.0,
                verticalAccuracy: 5.0,
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
