//
//  RouteGeometryTests.swift
//  ESP32NavAppTests
//
//  Pure geometry and route progress unit tests for P1 validation.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

final class RouteGeometryTests: XCTestCase {

    // MARK: - Test 1: Straight Route Projection

    func testStraightRouteProjection() {
        // Point A to Point B directly East along latitude 10.762622
        let coordA = CLLocationCoordinate2D(latitude: 10.762622, longitude: 106.660172)
        let coordB = CLLocationCoordinate2D(latitude: 10.762622, longitude: 106.670172)
        let route = NavRoute(
            coordinates: [coordA, coordB],
            steps: [
                NavStep(coordinate: coordB, distanceMeters: 1093.0, durationSeconds: 100.0, streetName: "Main St", maneuverType: .arrive, instruction: "Arrive")
            ],
            totalDistanceMeters: 1093.0,
            totalDurationSeconds: 100.0
        )

        XCTAssertEqual(route.geometry.segmentCount, 1)
        let totalDist = route.geometry.totalDistanceMeters
        XCTAssertGreaterThan(totalDist, 1000.0)

        // GPS point beside the middle (~22m North)
        let midLon = (coordA.longitude + coordB.longitude) / 2.0
        let testGPS = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.762822, longitude: midLon),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 10,
            timestamp: Date()
        )

        guard let proj = route.geometry.project(location: testGPS) else {
            XCTFail("Projection should not be nil")
            return
        }

        XCTAssertEqual(proj.segmentIndex, 0)
        XCTAssertEqual(proj.segmentFraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(proj.lateralDistanceMeters, 22.26, accuracy: 1.0)
        XCTAssertEqual(proj.distanceAlongRouteMeters, totalDist * 0.5, accuracy: 2.0)
    }

    // MARK: - Test 2: Multi-Segment Route Cumulative Distances

    func testMultiSegmentRouteCumulativeDistances() {
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.001, longitude: 106.0)      // ~111.3m North
        let p2 = CLLocationCoordinate2D(latitude: 10.001, longitude: 106.002)    // ~219.2m East
        let p3 = CLLocationCoordinate2D(latitude: 10.003, longitude: 106.002)    // ~222.6m North

        let geometry = RouteGeometry(coordinates: [p0, p1, p2, p3])

        XCTAssertEqual(geometry.cumulativeDistances.count, 4)
        XCTAssertEqual(geometry.cumulativeDistances[0], 0.0, accuracy: 1e-4)
        XCTAssertEqual(geometry.cumulativeDistances[1], 111.32, accuracy: 1.0)
        XCTAssertEqual(geometry.cumulativeDistances[2], 111.32 + 219.25, accuracy: 2.0)
        XCTAssertEqual(geometry.cumulativeDistances[3], geometry.totalDistanceMeters, accuracy: 1e-4)

        // Project point near the middle of Segment 1 (between p1 and p2)
        let testLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.00105, longitude: 106.0010),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 5,
            timestamp: Date()
        )
        guard let proj = geometry.project(location: testLoc) else {
            XCTFail("Projection should succeed")
            return
        }

        XCTAssertEqual(proj.segmentIndex, 1)
        XCTAssertEqual(proj.segmentFraction, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(proj.distanceAlongRouteMeters, geometry.cumulativeDistances[1])
        XCTAssertLessThan(proj.distanceAlongRouteMeters, geometry.cumulativeDistances[2])
    }

    // MARK: - Test 3: Backward Snap Prevention

    func testBackwardSnapPrevention() {
        // Parallel street geometry:
        // Segment 0: (10.0, 106.0) to (10.005, 106.0) [Northbound, 0 to 556m]
        // Segment 1: (10.005, 106.0) to (10.005, 106.0003) [East connector, 556m to 589m]
        // Segment 2: (10.005, 106.0003) to (10.0, 106.0003) [Southbound parallel, 589m to 1145m]
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0)
        let p2 = CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0003)
        let p3 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0003)

        let geometry = RouteGeometry(coordinates: [p0, p1, p2, p3])

        // User is currently at along-route progress ~867m on Segment 2 (driving South)
        let prevProj = RouteProjection(
            coordinate: CLLocationCoordinate2D(latitude: 10.0025, longitude: 106.0003),
            segmentIndex: 2,
            segmentFraction: 0.5,
            lateralDistanceMeters: 0.0,
            distanceAlongRouteMeters: geometry.cumulativeDistances[2] + (geometry.cumulativeDistances[3] - geometry.cumulativeDistances[2]) * 0.5
        )

        // GPS jitter places user equidistant (16m) between Segment 0 (Northbound at 278m) and Segment 2 (Southbound at 867m)
        // In fact, place it slightly closer (14m) to Segment 0!
        let jitterLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.0025, longitude: 106.00013),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 5,
            course: 180, // heading South
            speed: 8,
            timestamp: Date()
        )

        let proj = geometry.project(location: jitterLoc, lastProjection: prevProj)
        XCTAssertNotNil(proj)

        // Must NOT snap backward 589m to Segment 0! Continuity gating must keep it on Segment 2.
        XCTAssertEqual(proj?.segmentIndex, 2)
        XCTAssertGreaterThan(proj?.distanceAlongRouteMeters ?? 0, 589.0)
    }

    // MARK: - Test 4: Forward Jump Prevention

    func testForwardJumpPrevention() {
        // Self-crossing route geometry:
        // Northbound on Ave A (lat 10.0 to 10.004, lon 106.0) [0m to 445m]
        // Loop East (lon 106.0 to 106.004 at lat 10.004) [445m to 882m]
        // South on Ave B (lat 10.004 to 10.001 at lon 106.004) [882m to 1215m]
        // West cross-street (lat 10.001, lon 106.004 to 105.998) [crosses Ave A at lat 10.001, lon 106.0]
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.0)
        let p2 = CLLocationCoordinate2D(latitude: 10.004, longitude: 106.0)
        let p3 = CLLocationCoordinate2D(latitude: 10.004, longitude: 106.004)
        let p4 = CLLocationCoordinate2D(latitude: 10.001, longitude: 106.004)
        let p5 = CLLocationCoordinate2D(latitude: 10.001, longitude: 105.998)

        let geometry = RouteGeometry(coordinates: [p0, p1, p2, p3, p4, p5])

        // User is currently at start of route (segment 0, progress ~50m)
        let prevProj = RouteProjection(
            coordinate: CLLocationCoordinate2D(latitude: 10.00045, longitude: 106.0),
            segmentIndex: 0,
            segmentFraction: 0.22,
            lateralDistanceMeters: 0.0,
            distanceAlongRouteMeters: 50.0
        )

        // GPS reading at the crossing point (latitude 10.001, longitude 106.0):
        // This is on Segment 0 (at ~111m) AND on Segment 4 (at ~1650m).
        let crossingGPS = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.001, longitude: 106.0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0, // heading North
            speed: 10,
            timestamp: Date()
        )

        let proj = geometry.project(location: crossingGPS, lastProjection: prevProj)
        XCTAssertNotNil(proj)

        // Must NOT jump +1500m ahead to Segment 4! Must remain on current Segment 0.
        XCTAssertEqual(proj?.segmentIndex, 0)
        XCTAssertLessThan(proj?.distanceAlongRouteMeters ?? 10000, 200.0)
    }

    // MARK: - Test 5: Maneuver Step Mapping

    func testManeuverMapping() {
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.001, longitude: 106.0)
        let p2 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.0)
        let p3 = CLLocationCoordinate2D(latitude: 10.003, longitude: 106.0)

        let step0 = NavStep(
            coordinate: p2,
            distanceMeters: 222.6,
            durationSeconds: 20.0,
            streetName: "First St",
            maneuverType: .turnRight,
            instruction: "Turn right onto Second St",
            beginShapeIndex: 0,
            endShapeIndex: 2
        )
        let step1 = NavStep(
            coordinate: p3,
            distanceMeters: 111.3,
            durationSeconds: 10.0,
            streetName: "Second St",
            maneuverType: .arrive,
            instruction: "Arrive at destination",
            beginShapeIndex: 2,
            endShapeIndex: 3
        )

        let geometry = RouteGeometry(coordinates: [p0, p1, p2, p3], steps: [step0, step1])

        XCTAssertEqual(geometry.maneuverDistancesAlongRoute.count, 2)
        XCTAssertEqual(geometry.maneuverDistancesAlongRoute[0], geometry.cumulativeDistances[2], accuracy: 1e-4)
        XCTAssertEqual(geometry.maneuverDistancesAlongRoute[1], geometry.totalDistanceMeters, accuracy: 1e-4)
        XCTAssertLessThan(geometry.maneuverDistancesAlongRoute[0], geometry.maneuverDistancesAlongRoute[1])
    }

    // MARK: - Test 6: Remaining Distance

    func testRemainingDistance() {
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.009, longitude: 106.0) // ~1001.8m
        let geometry = RouteGeometry(coordinates: [p0, p1])

        let total = geometry.totalDistanceMeters
        XCTAssertEqual(total, 1001.8, accuracy: 1.0)

        // At 350m along route:
        let rem1 = geometry.remainingDistance(from: 350.0)
        XCTAssertEqual(rem1, total - 350.0, accuracy: 1e-4)

        // At destination:
        let rem2 = geometry.remainingDistance(from: total)
        XCTAssertEqual(rem2, 0.0, accuracy: 1e-4)

        // Past destination (clamped to zero):
        let rem3 = geometry.remainingDistance(from: total + 50.0)
        XCTAssertEqual(rem3, 0.0, accuracy: 1e-4)
    }

    // MARK: - Test 7: Distance To Turn (Along Route vs Straight-Line)

    func testDistanceToTurnAlongRoute() {
        // L-shaped road:
        // Segment 0: (10.0, 106.0) to (10.002, 106.0) [North 222.6m]
        // Segment 1: (10.002, 106.0) to (10.002, 106.002) [East 219.2m to Turn at corner]
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.0)
        let p2 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.002)

        let stepTurn = NavStep(
            coordinate: p2,
            distanceMeters: 441.8,
            durationSeconds: 40.0,
            streetName: "Corner St",
            maneuverType: .turnRight,
            instruction: "Turn right",
            beginShapeIndex: 0,
            endShapeIndex: 2
        )

        let geometry = RouteGeometry(coordinates: [p0, p1, p2], steps: [stepTurn])

        // User is at start of route (p0)
        let dTurn = geometry.distanceToManeuver(stepIndex: 0, from: 0.0)
        XCTAssertEqual(dTurn, geometry.totalDistanceMeters, accuracy: 1.0) // ~441.8m along route

        // Straight-line Euclidean distance from p0 to p2 is hypotenuse: sqrt(222.6^2 + 219.2^2) ≈ 312.4m
        let euclidean = RouteGeometry.distanceBetween(p0, p2)
        XCTAssertEqual(euclidean, 312.4, accuracy: 2.0)

        // Authoritative route-based distance MUST be larger than straight-line Euclidean distance!
        XCTAssertGreaterThan(dTurn, euclidean + 100.0)
    }

    // MARK: - Test 8: Reroute Route Reset

    func testRerouteRouteReset() {
        // Route A: 500m
        let rACoords = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0045, longitude: 106.0)
        ]
        let routeA = NavRoute(
            coordinates: rACoords,
            steps: [NavStep(coordinate: rACoords[1], distanceMeters: 500.0, durationSeconds: 50.0, streetName: "Route A", maneuverType: .arrive, instruction: "Arrive")],
            totalDistanceMeters: 500.0,
            totalDurationSeconds: 50.0
        )

        // Route B: 1200m
        let rBCoords = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.011)
        ]
        let routeB = NavRoute(
            coordinates: rBCoords,
            steps: [NavStep(coordinate: rBCoords[1], distanceMeters: 1200.0, durationSeconds: 120.0, streetName: "Route B", maneuverType: .arrive, instruction: "Arrive")],
            totalDistanceMeters: 1200.0,
            totalDurationSeconds: 120.0
        )

        // Progress on Route A
        let locA = CLLocation(latitude: 10.002, longitude: 106.0)
        let projA = routeA.geometry.project(location: locA)
        XCTAssertNotNil(projA)
        XCTAssertEqual(projA?.distanceAlongRouteMeters ?? 0, 222.6, accuracy: 2.0)

        // After reroute to Route B: reset projection state, project on Route B
        let locB = CLLocation(latitude: 10.0, longitude: 106.002)
        let projB = routeB.geometry.project(location: locB, lastProjection: nil)
        XCTAssertNotNil(projB)
        XCTAssertEqual(projB?.segmentIndex, 0)
        XCTAssertEqual(projB?.distanceAlongRouteMeters ?? 0, 219.2, accuracy: 2.0)

        // Verify remaining distance belongs strictly to Route B
        let remainingB = routeB.geometry.remainingDistance(from: projB?.distanceAlongRouteMeters ?? 0)
        XCTAssertEqual(remainingB, routeB.geometry.totalDistanceMeters - (projB?.distanceAlongRouteMeters ?? 0), accuracy: 1e-4)
        XCTAssertGreaterThan(remainingB, 900.0) // On Route B (~980m remaining), whereas Route A was only 500m total!
    }
}
