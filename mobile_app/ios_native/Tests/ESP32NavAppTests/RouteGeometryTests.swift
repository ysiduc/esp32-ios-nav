//
//  RouteGeometryTests.swift
//  ESP32NavAppTests
//
//  Comprehensive pure geometry, temporal continuity, MapKit mapping,
//  and navigation session state unit tests for P1 / P1.1 validation.
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

        // GPS jitter places user closer (14m) to Segment 0 (Northbound at 278m) than Segment 2 (Southbound at 867m)
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

    // MARK: - Test 5: Temporal Continuity — 1-Second Forward Jump Gating

    func testTemporalForwardJumpOneSecond() {
        // Route:
        // Segment 0: (10.0, 106.0) to (10.001, 106.0) [0m to 111m]
        // Segment 1: (10.001, 106.0) to (10.002, 106.0) [111m to 222m]
        // Segment 2: loop around and cross near 10.0012, 106.0 at ~500m
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.001, longitude: 106.0)
        let p2 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.0)
        let p3 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.002)
        let p4 = CLLocationCoordinate2D(latitude: 10.0012, longitude: 106.002)
        let p5 = CLLocationCoordinate2D(latitude: 10.0012, longitude: 105.998) // crosses segment 1

        let geometry = RouteGeometry(coordinates: [p0, p1, p2, p3, p4, p5])

        let baseTime = Date()
        let prevProj = RouteProjection(
            coordinate: CLLocationCoordinate2D(latitude: 10.0009, longitude: 106.0),
            segmentIndex: 0,
            segmentFraction: 0.9,
            lateralDistanceMeters: 0.0,
            distanceAlongRouteMeters: 100.0
        )

        // GPS sample 1 second later (dt = 1.0s), vehicle speed 10 m/s (~36 km/h)
        // Candidate near crossing (lat 10.0012, lon 106.0) is on Segment 1 (~133m) AND Segment 4 (~600m)
        let oneSecondGPS = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.0012, longitude: 106.0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 10.0,
            timestamp: baseTime.addingTimeInterval(1.0)
        )

        let proj = geometry.project(
            location: oneSecondGPS,
            lastProjection: prevProj,
            lastMatchedTimestamp: baseTime
        )

        XCTAssertNotNil(proj)
        // In 1 second, vehicle could only move ~10-25m. Local candidate at ~133m (Segment 1) must win!
        XCTAssertEqual(proj?.segmentIndex, 1)
        XCTAssertLessThan(proj?.distanceAlongRouteMeters ?? 1000, 200.0)
    }

    // MARK: - Test 6: Temporal Continuity — Delayed GPS Sample Allowed

    func testTemporalDelayedGPSSampleAllowed() {
        let p0 = CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0)
        let p1 = CLLocationCoordinate2D(latitude: 10.001, longitude: 106.0)      // ~111m
        let p2 = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.0)      // ~222m
        let p3 = CLLocationCoordinate2D(latitude: 10.003, longitude: 106.0)      // ~333m

        let geometry = RouteGeometry(coordinates: [p0, p1, p2, p3])

        let baseTime = Date()
        let prevProj = RouteProjection(
            coordinate: p0,
            segmentIndex: 0,
            segmentFraction: 0.0,
            lateralDistanceMeters: 0.0,
            distanceAlongRouteMeters: 0.0
        )

        // Delayed GPS sample 12 seconds later (e.g. background sleep / tunnel exit)
        // Vehicle traveled at 15 m/s (~54 km/h) for 12s = ~180m forward (Segment 1)
        let delayedGPS = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.0016, longitude: 106.0),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            course: 0,
            speed: 15.0,
            timestamp: baseTime.addingTimeInterval(12.0)
        )

        let proj = geometry.project(
            location: delayedGPS,
            lastProjection: prevProj,
            lastMatchedTimestamp: baseTime
        )

        XCTAssertNotNil(proj)
        // Because 12s elapsed, a 180m advance is physically valid and must NOT be rejected by forward jump gating!
        XCTAssertEqual(proj?.segmentIndex, 1)
        XCTAssertGreaterThan(proj?.distanceAlongRouteMeters ?? 0, 150.0)
    }

    // MARK: - Test 7: Maneuver Step Mapping

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
            maneuverType: .right,
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

    // MARK: - Test 8: MapKit Shape Mapping Monotonicity

    func testMapKitShapeMappingMonotonic() {
        // Full route with 10 coordinates
        var fullCoords: [CLLocationCoordinate2D] = []
        for i in 0..<10 {
            fullCoords.append(CLLocationCoordinate2D(latitude: 10.0 + Double(i) * 0.001, longitude: 106.0))
        }

        // 3 sub-polylines representing steps
        let step0Coords = Array(fullCoords[0...3])
        let step1Coords = Array(fullCoords[3...6])
        let step2Coords = Array(fullCoords[6...9])

        let mappings = RouteGeometry.mapStepPolylinesToIndices(
            stepPolylines: [step0Coords, step1Coords, step2Coords],
            fullPolyline: fullCoords
        )

        XCTAssertEqual(mappings.count, 3)

        // Verify shape index ranges
        XCTAssertEqual(mappings[0].beginShapeIndex, 0)
        XCTAssertEqual(mappings[0].endShapeIndex, 3)
        XCTAssertEqual(mappings[1].beginShapeIndex, 3)
        XCTAssertEqual(mappings[1].endShapeIndex, 6)
        XCTAssertEqual(mappings[2].beginShapeIndex, 6)
        XCTAssertEqual(mappings[2].endShapeIndex, 9)

        // Strict monotonicity check: begin_0 <= end_0 <= begin_1 <= end_1 <= begin_2 <= end_2
        XCTAssertLessThanOrEqual(mappings[0].beginShapeIndex, mappings[0].endShapeIndex)
        XCTAssertLessThanOrEqual(mappings[0].endShapeIndex, mappings[1].beginShapeIndex)
        XCTAssertLessThanOrEqual(mappings[1].beginShapeIndex, mappings[1].endShapeIndex)
        XCTAssertLessThanOrEqual(mappings[1].endShapeIndex, mappings[2].beginShapeIndex)
        XCTAssertLessThanOrEqual(mappings[2].beginShapeIndex, mappings[2].endShapeIndex)
    }

    // MARK: - Test 9: Remaining Distance

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

    // MARK: - Test 10: Distance To Turn (Along Route vs Straight-Line)

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
            maneuverType: .right,
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

    // MARK: - Test 11: Real NavigationSessionManager Route Replacement State Test

    @MainActor
    func testNavigationSessionManagerReplaceActiveRoute() {
        let manager = NavigationSessionManager()

        let coordsA = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.005, longitude: 106.0)
        ]
        let stepA = NavStep(
            coordinate: coordsA[1],
            distanceMeters: 556.0,
            durationSeconds: 60.0,
            streetName: "Route A St",
            maneuverType: .arrive,
            instruction: "Arrive"
        )
        let routeA = NavRoute(coordinates: coordsA, steps: [stepA], totalDistanceMeters: 556.0, totalDurationSeconds: 60.0)
        let destination = NavigationDestination(coordinate: coordsA[1], name: "Test Destination")

        // Start Navigation with Route A
        manager.startNavigation(route: routeA, destination: destination)
        let initialRouteGen = manager.activeRouteGeneration
        let initialSessionGen = manager.sessionGeneration

        XCTAssertEqual(manager.state, .navigating)
        XCTAssertEqual(manager.activeRoute?.totalDistanceMeters, 556.0)
        XCTAssertEqual(manager.currentManeuverStepIndex, 0)
        XCTAssertEqual(manager.currentPolylineSegmentIndex, 0)

        // Route B (replacement reroute)
        let coordsB = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.012)
        ]
        let stepB = NavStep(
            coordinate: coordsB[1],
            distanceMeters: 1315.0,
            durationSeconds: 150.0,
            streetName: "Route B Ave",
            maneuverType: .arrive,
            instruction: "Arrive"
        )
        let routeB = NavRoute(coordinates: coordsB, steps: [stepB], totalDistanceMeters: 1315.0, totalDurationSeconds: 150.0)

        // Replace active route with Route B
        manager.replaceActiveRoute(routeB)

        // Verifications:
        // 1. Session generation preserved (no false session restart)
        XCTAssertEqual(manager.sessionGeneration, initialSessionGen)
        // 2. Route revision atomically incremented
        XCTAssertEqual(manager.activeRouteGeneration, initialRouteGen + 1)
        // 3. Active route swapped to Route B
        XCTAssertEqual(manager.activeRoute?.totalDistanceMeters, 1315.0)
        // 4. Maneuver step and polyline segment indices reset to 0 for Route B
        XCTAssertEqual(manager.currentManeuverStepIndex, 0)
        XCTAssertEqual(manager.currentPolylineSegmentIndex, 0)
        // 5. Temporal state reset (no stale timestamps inherited from Route A)
        XCTAssertNil(manager.lastMatchedTimestamp)
        // 6. Navigation destination preserved
        XCTAssertEqual(manager.navigationDestination?.name, "Test Destination")
    }

    // MARK: - Test 12: Route Geometry Reset Concept

    func testRouteGeometryResetConcept() {
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
