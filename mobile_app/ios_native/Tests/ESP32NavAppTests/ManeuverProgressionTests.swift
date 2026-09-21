//
//  ManeuverProgressionTests.swift
//  Unit tests for maneuver begin/end semantics, tunnel/bridge fixtures, and pass recovery.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

@MainActor
final class ManeuverProgressionTests: XCTestCase {

    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    // MARK: - Test 1: Maneuver Begin/End Semantics (Requirement 47)

    func testManeuverBeginEndSemantics_AdvancesAtActionPoint() {
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...30 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800 + Double(i) * 0.00001))
        }

        let step0 = NavStep(
            coordinate: coords[10],
            distanceMeters: 10.0,
            durationSeconds: 5.0,
            streetName: "Đoạn 0",
            maneuverType: .straight,
            instruction: "Khởi hành",
            beginShapeIndex: 0,
            endShapeIndex: 10
        )
        let step1 = NavStep(
            coordinate: coords[20],
            distanceMeters: 10.0,
            durationSeconds: 5.0,
            streetName: "Đoạn 1",
            maneuverType: .right,
            instruction: "Rẽ phải",
            beginShapeIndex: 10,
            endShapeIndex: 20
        )
        let step2 = NavStep(
            coordinate: coords[30],
            distanceMeters: 10.0,
            durationSeconds: 5.0,
            streetName: "Đoạn 2",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 20,
            endShapeIndex: 30
        )

        let route = NavRoute(
            coordinates: coords,
            steps: [step0, step1, step2],
            totalDistanceMeters: routeDistance(coords),
            totalDurationSeconds: 15.0
        )

        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coords.last!, name: "Đích"))

        let begin0 = route.geometry.maneuverBeginDistancesAlongRoute[0]
        let begin1 = route.geometry.maneuverBeginDistancesAlongRoute[1]
        let begin2 = route.geometry.maneuverBeginDistancesAlongRoute[2]

        XCTAssertEqual(begin0, 0.0, accuracy: 1e-3)
        XCTAssertGreaterThan(begin1, begin0)
        XCTAssertGreaterThan(begin2, begin1)

        // At progress ~8m (< begin1): upcoming maneuver is step 1 (Rẽ phải)
        var simTime = baseDate
        // Progress toward step 1 action point at 10m
        for i in [2, 5, 8] {
            let loc = CLLocation(
                coordinate: coords[i],
                altitude: 10.0,
                horizontalAccuracy: 3.0,
                verticalAccuracy: 3.0,
                course: 90.0,
                speed: 3.0,
                timestamp: simTime
            )
            session.ingestLocation(loc)
            simTime = simTime.addingTimeInterval(1.0)
        }
        XCTAssertEqual(session.currentManeuverStepIndex, 1, "At progress ~8m, upcoming step must be step 1")
        XCTAssertEqual(session.activeProgress.maneuver, .right)

        // Cross step 1 action point (> 10m + tolerance)
        for i in [11, 13, 14] {
            let loc = CLLocation(
                coordinate: coords[i],
                altitude: 10.0,
                horizontalAccuracy: 3.0,
                verticalAccuracy: 3.0,
                course: 90.0,
                speed: 3.0,
                timestamp: simTime
            )
            session.ingestLocation(loc)
            simTime = simTime.addingTimeInterval(1.0)
        }
        XCTAssertEqual(session.currentManeuverStepIndex, 2, "Once step 1 action is passed, upcoming step must advance to step 2")

        // Cross step 2
        for i in [21, 23] {
            let loc = CLLocation(
                coordinate: coords[i],
                altitude: 10.0,
                horizontalAccuracy: 3.0,
                verticalAccuracy: 3.0,
                course: 90.0,
                speed: 3.0,
                timestamp: simTime
            )
            session.ingestLocation(loc)
            simTime = simTime.addingTimeInterval(1.0)
        }
        XCTAssertEqual(session.currentManeuverStepIndex, 2, "At progress 22m, step 2 is active without stale step 1")
    }

    // MARK: - Test 2: Tunnel Regression Fixture (Requirement 35)

    func testTunnelGuidance_AdvancesPromptlyPastTunnel() {
        // Modeled on real Hanoi field test: Hầm chui Kim Đồng - Giải Phóng
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...15 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000 + Double(i) * 0.0009, longitude: 105.800))
        }

        let step0 = NavStep(
            coordinate: coords[5],
            distanceMeters: 500.0,
            durationSeconds: 40.0,
            streetName: "Đường Kim Đồng",
            maneuverType: .straight,
            instruction: "Đi thẳng trên Kim Đồng",
            beginShapeIndex: 0,
            endShapeIndex: 5
        )
        let step1 = NavStep(
            coordinate: coords[10],
            distanceMeters: 500.0,
            durationSeconds: 40.0,
            streetName: "Hầm chui Kim Đồng - Giải Phóng",
            maneuverType: .straight,
            instruction: "Vào Hầm chui Kim Đồng - Giải Phóng",
            beginShapeIndex: 5,
            endShapeIndex: 10
        )
        let step2 = NavStep(
            coordinate: coords[15],
            distanceMeters: 500.0,
            durationSeconds: 40.0,
            streetName: "Đường Giải Phóng",
            maneuverType: .straight,
            instruction: "Tiếp tục trên Giải Phóng",
            beginShapeIndex: 10,
            endShapeIndex: 15
        )
        let step3 = NavStep(
            coordinate: coords[15],
            distanceMeters: 0.0,
            durationSeconds: 0.0,
            streetName: "Đích",
            maneuverType: .arrive,
            instruction: "Đã đến đích",
            beginShapeIndex: 15,
            endShapeIndex: 15
        )

        let route = NavRoute(
            coordinates: coords,
            steps: [step0, step1, step2, step3],
            totalDistanceMeters: routeDistance(coords),
            totalDurationSeconds: 120.0
        )

        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coords.last!, name: "Đích"))

        var time = baseDate

        // 1. Approach tunnel (coord 3, ~300m) -> upcoming is Step 1 (Tunnel at 500m)
        let approachLoc = CLLocation(
            coordinate: coords[3],
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 10.0,
            timestamp: time
        )
        session.ingestLocation(approachLoc)
        XCTAssertEqual(session.currentManeuverStepIndex, 1, "Before tunnel, upcoming maneuver must be the tunnel")
        XCTAssertEqual(session.activeProgress.nextStreetName, "Hầm chui Kim Đồng - Giải Phóng")

        // 2. Past tunnel entrance inside tunnel (coord 6, ~600m) -> tunnel entrance (500m) passed, upcoming advances to post-tunnel step
        // 300m physical travel at 10 m/s = 30 seconds
        time = time.addingTimeInterval(30.0)
        let insideLoc = CLLocation(
            coordinate: coords[6],
            altitude: 0.0,
            horizontalAccuracy: 8.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 10.0,
            timestamp: time
        )
        session.ingestLocation(insideLoc)
        XCTAssertEqual(session.currentManeuverStepIndex, 2, "Once tunnel entrance is passed, upcoming maneuver must advance to post-tunnel road")
        XCTAssertEqual(session.activeProgress.nextStreetName, "Đường Giải Phóng")

        // Link maneuver progression to authoritative route trimming (Requirement 38)
        XCTAssertFalse(session.remainingPolyline.isEmpty)
        let firstRemaining = session.remainingPolyline.first!
        let distAlong = route.geometry.project(location: CLLocation(latitude: firstRemaining.latitude, longitude: firstRemaining.longitude))?.distanceAlongRouteMeters ?? 0.0
        XCTAssertGreaterThanOrEqual(distAlong, 500.0, "Remaining polyline first coordinate must be at or past tunnel entrance (500m) when instruction advances")

        // 3. Past tunnel exit (coord 11, ~1100m) -> completely past tunnel exit (1000m)
        // 500m physical travel at 10 m/s = 50 seconds
        time = time.addingTimeInterval(50.0)
        let pastExitLoc = CLLocation(
            coordinate: coords[11],
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 10.0,
            timestamp: time
        )
        session.ingestLocation(pastExitLoc)

        // Tunnel instruction must NOT remain active
        XCTAssertNotEqual(session.activeProgress.nextStreetName, "Hầm chui Kim Đồng - Giải Phóng", "Tunnel instruction must NOT remain active past tunnel exit")
        XCTAssertGreaterThanOrEqual(session.currentManeuverStepIndex, 2)
    }

    // MARK: - Test 3: Initial Depart Maneuver Handling (Requirement 32)

    func testInitialDepartManeuver_AdvancesPromptlyWhenMoving() {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.804)
        ]

        let step0 = NavStep(
            coordinate: coords[0],
            distanceMeters: 200.0,
            durationSeconds: 20.0,
            streetName: "Lê Duẩn",
            maneuverType: .straight,
            instruction: "Khởi hành đi về hướng Bắc",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        let step1 = NavStep(
            coordinate: coords[1],
            distanceMeters: 400.0,
            durationSeconds: 40.0,
            streetName: "Trần Nhân Tông",
            maneuverType: .right,
            instruction: "Rẽ phải vào Trần Nhân Tông",
            beginShapeIndex: 1,
            endShapeIndex: 2
        )

        let route = NavRoute(coordinates: coords, steps: [step0, step1], totalDistanceMeters: 600.0, totalDurationSeconds: 60.0)
        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coords[2], name: "Đích"))

        // Initial sample at start (0m)
        let startLoc = CLLocation(
            coordinate: coords[0],
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 0.0,
            timestamp: baseDate
        )
        session.ingestLocation(startLoc)

        // Once vehicle starts moving forward (progress ~20m)
        let moveLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.0002, longitude: 105.800),
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 8.0,
            timestamp: baseDate.addingTimeInterval(2.0)
        )
        session.ingestLocation(moveLoc)

        // Must show upcoming turn step 1, not depart forever
        XCTAssertEqual(session.currentManeuverStepIndex, 1, "Must advance to step 1 upcoming turn once moving")
        XCTAssertEqual(session.activeProgress.maneuver, .right)
    }

    // MARK: - Test 4: Maneuver Pass Recovery (Requirement 34)

    func testManeuverPassRecovery_AdvancesThroughMultiplePassedStepsInOneUpdate() {
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...20 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000 + Double(i) * 0.0002, longitude: 105.800))
        }

        let steps = [
            NavStep(coordinate: coords[5], distanceMeters: 100.0, durationSeconds: 10.0, streetName: "Đoạn 1", maneuverType: .straight, instruction: "Đi thẳng", beginShapeIndex: 0, endShapeIndex: 5),
            NavStep(coordinate: coords[10], distanceMeters: 100.0, durationSeconds: 10.0, streetName: "Đoạn 2", maneuverType: .right, instruction: "Rẽ phải", beginShapeIndex: 5, endShapeIndex: 10),
            NavStep(coordinate: coords[15], distanceMeters: 100.0, durationSeconds: 10.0, streetName: "Đoạn 3", maneuverType: .left, instruction: "Rẽ trái", beginShapeIndex: 10, endShapeIndex: 15),
            NavStep(coordinate: coords[20], distanceMeters: 100.0, durationSeconds: 10.0, streetName: "Đích", maneuverType: .arrive, instruction: "Đến đích", beginShapeIndex: 15, endShapeIndex: 20)
        ]

        let route = NavRoute(coordinates: coords, steps: steps, totalDistanceMeters: routeDistance(coords), totalDurationSeconds: 40.0)
        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: coords.last!, name: "Đích"))

        // GPS skip: vehicle jumps from coord 2 (before step 1) to coord 12 (past step 1 and step 2)
        let jumpLoc = CLLocation(
            coordinate: coords[12],
            altitude: 10.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0.0,
            speed: 15.0,
            timestamp: baseDate
        )
        session.ingestLocation(jumpLoc)

        // While loop must advance through all passed boundaries in single update
        XCTAssertGreaterThanOrEqual(session.currentManeuverStepIndex, 2, "Must advance past all skipped steps")
    }

    // MARK: - Test 5: Step Index Validation Graceful Fallback (Requirement 36)

    func testStepIndexValidation_FallsBackWithoutCrashing() {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.001, longitude: 105.800)
        ]

        let corruptedStep = NavStep(
            coordinate: coords[1],
            distanceMeters: 100.0,
            durationSeconds: 10.0,
            streetName: "Lỗi",
            maneuverType: .straight,
            instruction: "Lỗi",
            beginShapeIndex: 999, // out of bounds
            endShapeIndex: 50     // invalid
        )

        let geometry = RouteGeometry(coordinates: coords, steps: [corruptedStep])
        XCTAssertEqual(geometry.maneuverBeginDistancesAlongRoute.count, 1)
        XCTAssertEqual(geometry.maneuverEndDistancesAlongRoute.count, 1)
        XCTAssertGreaterThanOrEqual(geometry.maneuverEndDistancesAlongRoute[0], geometry.maneuverBeginDistancesAlongRoute[0])
    }

    // MARK: - Test 6: Real Valhalla Step Indices Flow Into RouteGeometry (Requirement 48)

    func testRealValhallaStepIndices_FlowIntoRouteGeometry() {
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...14 {
            coords.append(CLLocationCoordinate2D(latitude: 21.000 + Double(i) * 0.0005, longitude: 105.800))
        }

        let step0 = NavStep(
            coordinate: coords[5],
            distanceMeters: 250.0,
            durationSeconds: 20.0,
            streetName: "Trần Hưng Đạo",
            maneuverType: .straight,
            instruction: "Đi thẳng trên Trần Hưng Đạo",
            beginShapeIndex: 0,
            endShapeIndex: 5
        )
        let step1 = NavStep(
            coordinate: coords[12],
            distanceMeters: 350.0,
            durationSeconds: 30.0,
            streetName: "Bà Triệu",
            maneuverType: .right,
            instruction: "Rẽ phải vào Bà Triệu",
            beginShapeIndex: 5,
            endShapeIndex: 12
        )
        let step2 = NavStep(
            coordinate: coords[14],
            distanceMeters: 100.0,
            durationSeconds: 10.0,
            streetName: "Đích",
            maneuverType: .arrive,
            instruction: "Đến đích",
            beginShapeIndex: 12,
            endShapeIndex: 14
        )

        let geometry = RouteGeometry(coordinates: coords, steps: [step0, step1, step2])

        XCTAssertEqual(geometry.maneuverBeginDistancesAlongRoute.count, 3)
        XCTAssertEqual(geometry.maneuverEndDistancesAlongRoute.count, 3)

        XCTAssertEqual(geometry.maneuverBeginDistancesAlongRoute[0], geometry.cumulativeDistances[0], accuracy: 1e-4)
        XCTAssertEqual(geometry.maneuverEndDistancesAlongRoute[0], geometry.cumulativeDistances[5], accuracy: 1e-4)

        XCTAssertEqual(geometry.maneuverBeginDistancesAlongRoute[1], geometry.cumulativeDistances[5], accuracy: 1e-4)
        XCTAssertEqual(geometry.maneuverEndDistancesAlongRoute[1], geometry.cumulativeDistances[12], accuracy: 1e-4)

        XCTAssertEqual(geometry.maneuverBeginDistancesAlongRoute[2], geometry.cumulativeDistances[12], accuracy: 1e-4)
        XCTAssertEqual(geometry.maneuverEndDistancesAlongRoute[2], geometry.cumulativeDistances[14], accuracy: 1e-4)
    }

    // Helper
    private func routeDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        var d = 0.0
        for i in 0..<(coords.count - 1) {
            d += RouteGeometry.distanceBetween(coords[i], coords[i+1])
        }
        return d
    }
}
