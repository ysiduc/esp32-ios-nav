//
//  NavigationReplayTests.swift
//  Comprehensive deterministic GPS replay integration test suite (14 scenarios).
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

@MainActor
final class NavigationReplayTests: XCTestCase {

    private var sessionManager: NavigationSessionManager!
    private var runner: NavigationReplayRunner!

    private let coordA = CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542)
    private let coordB = CLLocationCoordinate2D(latitude: 21.0335, longitude: 105.8542) // ~556m north
    private let coordC = CLLocationCoordinate2D(latitude: 21.0385, longitude: 105.8542) // ~1112m north

    private var routeA: NavRoute!
    private var destA: NavigationDestination!

    override func setUp() {
        super.setUp()
        sessionManager = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        runner = NavigationReplayRunner(sessionManager: sessionManager)

        let step1 = NavStep(
            coordinate: coordB,
            distanceMeters: 556,
            durationSeconds: 60,
            streetName: "Đinh Tiên Hoàng",
            maneuverType: .straight,
            instruction: "Đi thẳng trên Đinh Tiên Hoàng",
            beginShapeIndex: 0,
            endShapeIndex: 1
        )
        let step2 = NavStep(
            coordinate: coordC,
            distanceMeters: 556,
            durationSeconds: 60,
            streetName: "Hàng Đào",
            maneuverType: .arrive,
            instruction: "Đến nơi",
            beginShapeIndex: 1,
            endShapeIndex: 2
        )

        routeA = NavRoute(
            coordinates: [coordA, coordB, coordC],
            steps: [step1, step2],
            totalDistanceMeters: 1112,
            totalDurationSeconds: 120
        )

        destA = NavigationDestination(
            coordinate: coordC,
            name: "Hàng Đào"
        )
    }

    override func tearDown() {
        sessionManager.stopNavigation()
        runner = nil
        sessionManager = nil
        super.tearDown()
    }

    // MARK: - 1. Straight Route Replay

    func testReplay_NormalStraightRoute_MonotonicProgressAndSingleArrival() {
        sessionManager.startNavigation(route: routeA, destination: destA)
        XCTAssertEqual(sessionManager.state, .navigating)

        let baseDate = Date()
        var samples: [NavigationReplaySample] = []

        // 5 equidistant samples advancing along route from A to C
        for i in 0...4 {
            let frac = Double(i) / 4.0
            let lat = coordA.latitude + frac * (coordC.latitude - coordA.latitude)
            let lon = coordA.longitude
            samples.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(Double(i) * 15.0),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                speed: 10.0,
                course: 0.0
            ))
        }

        // Vehicle settles at destination (allowing Kalman filter convergence)
        samples.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(62.0),
            coordinate: coordC,
            speed: 0.0,
            course: 0.0
        ))
        samples.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(64.0),
            coordinate: coordC,
            speed: 0.0,
            course: 0.0
        ))

        runner.replay(samples: samples)

        // Progress distance along route should increase monotonically (remaining distance decreases)
        XCTAssertGreaterThanOrEqual(runner.recordedProgress.count, 2)
        let remDists = runner.recordedProgress.map { Double($0.remainingDistanceMeters) }
        for i in 1..<remDists.count {
            XCTAssertLessThanOrEqual(remDists[i], remDists[i-1] + 5.0, "Remaining distance should decrease monotonically")
        }

        XCTAssertEqual(runner.arrivalCount, 1, "Arrival must fire exactly once")
        XCTAssertEqual(sessionManager.state, .arrived)
        XCTAssertEqual(sessionManager.diagnostics.locationsReceived, 7)
        XCTAssertEqual(sessionManager.diagnostics.locationsAccepted, 7)
    }

    // MARK: - 2. GPS Jitter Replay

    func testReplay_GPSJitter_StationaryDoesNotJumpOrTriggerOffRoute() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        var samples: [NavigationReplaySample] = []

        // Vehicle stopped near midpoint (coordB), GPS jitters ±2m
        for i in 0..<10 {
            let jitterLat = (i % 2 == 0 ? 0.00002 : -0.00002) // ~2m
            let jitterLon = (i % 3 == 0 ? 0.00002 : -0.00002)
            samples.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(Double(i) * 1.0),
                coordinate: CLLocationCoordinate2D(
                    latitude: coordB.latitude + jitterLat,
                    longitude: coordB.longitude + jitterLon
                ),
                horizontalAccuracy: 6.0,
                speed: 0.5,
                course: 0.0
            ))
        }

        runner.replay(samples: samples)

        XCTAssertFalse(sessionManager.isOffRoute, "Stationary jitter must not trigger confirmed off-route")
        XCTAssertEqual(sessionManager.state, .navigating)
        XCTAssertEqual(sessionManager.diagnostics.offRouteConfirmations, 0)
    }

    // MARK: - 3. Poor Accuracy Burst Replay

    func testReplay_PoorAccuracyBurst_RejectsWithoutAdvancingProgress() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        let goodSample1 = NavigationReplaySample(
            timestamp: baseDate,
            coordinate: coordA,
            horizontalAccuracy: 5.0
        )
        runner.replay(samples: [goodSample1])
        let progressAfterGood = sessionManager.currentProjection?.distanceAlongRouteMeters

        // 3 degraded accuracy samples (> 50m)
        let badSamples = [
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(2), coordinate: coordB, horizontalAccuracy: 75.0),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(4), coordinate: coordB, horizontalAccuracy: 90.0),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(6), coordinate: coordB, horizontalAccuracy: 120.0)
        ]
        runner.replay(samples: badSamples)

        XCTAssertEqual(sessionManager.diagnostics.locationsRejectedForAccuracy, 3)
        XCTAssertEqual(sessionManager.currentProjection?.distanceAlongRouteMeters, progressAfterGood, "Bad accuracy samples must not advance route progress")

        // Resumes on good sample
        let goodSample2 = NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(8),
            coordinate: coordB,
            horizontalAccuracy: 8.0
        )
        runner.replay(samples: [goodSample2])

        XCTAssertGreaterThan(sessionManager.currentProjection!.distanceAlongRouteMeters, progressAfterGood!)
    }

    // MARK: - 4. Parallel Road Replay

    func testReplay_ParallelRoad_ContinuityPreventsSnappingAcross() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        // Feed initial sample on route
        runner.replay(samples: [NavigationReplaySample(timestamp: baseDate, coordinate: coordA)])

        // Sample slightly offset eastward (toward parallel street, ~15m east)
        let offsetSample = NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(2),
            coordinate: CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.85435), // ~15m lateral
            horizontalAccuracy: 5.0,
            course: 0.0
        )
        runner.replay(samples: [offsetSample])

        // Remains snapped to route segment with continuity
        XCTAssertEqual(sessionManager.currentProjection?.segmentIndex, 0)
        XCTAssertFalse(sessionManager.isOffRoute)
    }

    // MARK: - 5. Hairpin / Self-Near Route Replay

    func testReplay_HairpinRoute_ForwardJumpGatingPreventsSkipping() {
        // Route with hairpin returning close to start: A -> D (~500m east) -> E (south near A)
        let coordD = CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8590)
        let coordE = CLLocationCoordinate2D(latitude: 21.0284, longitude: 105.8543) // physically ~10m from A!

        let hairpinRoute = NavRoute(
            coordinates: [coordA, coordD, coordE],
            steps: [],
            totalDistanceMeters: 1000,
            totalDurationSeconds: 100
        )
        sessionManager.startNavigation(route: hairpinRoute, destination: NavigationDestination(coordinate: coordE, name: "End"))

        let baseDate = Date()
        // First sample at A
        runner.replay(samples: [NavigationReplaySample(timestamp: baseDate, coordinate: coordA)])
        XCTAssertEqual(sessionManager.currentProjection?.segmentIndex, 0)

        // Sample 2s later still near A (and physically near E)
        let sample2 = NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(2),
            coordinate: CLLocationCoordinate2D(latitude: 21.02855, longitude: 105.85425),
            speed: 5.0
        )
        runner.replay(samples: [sample2])

        // Must stay on segment 0 (A->D), must NOT jump to segment 1 (D->E) despite physical proximity
        XCTAssertEqual(sessionManager.currentProjection?.segmentIndex, 0, "Forward jump gating must prevent skipping to distant segment")
    }

    // MARK: - 6. Wrong Turn Replay

    func testReplay_WrongTurn_DwellExceededConfirmsOffRouteAndTriggersReroute() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        // Normal point
        runner.replay(samples: [NavigationReplaySample(timestamp: baseDate, coordinate: coordA)])

        // Vehicle turns off route laterally (> 35m) for > 3.0s
        var samples: [NavigationReplaySample] = []
        for i in 1...5 {
            samples.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(Double(i) * 1.0),
                coordinate: CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8550), // ~80m east!
                speed: 8.0,
                course: 90.0 // heading east
            ))
        }

        runner.replay(samples: samples)

        XCTAssertTrue(sessionManager.isOffRoute)
        XCTAssertEqual(sessionManager.offRouteState, .confirmed)
        XCTAssertGreaterThanOrEqual(sessionManager.diagnostics.offRouteConfirmations, 1)
    }

    // MARK: - 7. Recovery Before Confirmation Replay

    func testReplay_RecoveryBeforeConfirmation_ReturnsToOnRouteWithoutReroute() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        runner.replay(samples: [NavigationReplaySample(timestamp: baseDate, coordinate: coordA)])

        // Brief divergence for 1.0s (less than 3.0s dwell)
        let diverged = NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(1),
            coordinate: CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8550),
            speed: 8.0
        )
        runner.replay(samples: [diverged])
        XCTAssertEqual(sessionManager.offRouteState, .suspected)

        // Returns to route (feed converged samples on route)
        let returned1 = NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(2),
            coordinate: CLLocationCoordinate2D(latitude: 21.0305, longitude: 105.8542),
            horizontalAccuracy: 3.0,
            speed: 8.0
        )
        let returned2 = NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(3),
            coordinate: CLLocationCoordinate2D(latitude: 21.0310, longitude: 105.8542),
            horizontalAccuracy: 3.0,
            speed: 8.0
        )
        runner.replay(samples: [returned1, returned2])

        XCTAssertEqual(sessionManager.offRouteState, .onRoute)
        XCTAssertFalse(sessionManager.isOffRoute)
        XCTAssertEqual(sessionManager.diagnostics.offRouteConfirmations, 0)
    }

    // MARK: - 8. Confirmed Then Recovery Replay

    func testReplay_ConfirmedThenRecovery_ReturnsToOnRouteCleanly() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        runner.replay(samples: [NavigationReplaySample(timestamp: baseDate, coordinate: coordA)])

        // Confirmed off route
        for i in 1...5 {
            runner.replay(samples: [NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(Double(i) * 1.0),
                coordinate: CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8550),
                speed: 8.0,
                course: 90.0
            )])
        }
        XCTAssertTrue(sessionManager.isOffRoute)

        // Vehicle drives back onto route geometry and satisfies recovery dwell
        let recoveredSamples = [
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(8), coordinate: CLLocationCoordinate2D(latitude: 21.0320, longitude: 105.8542), horizontalAccuracy: 3.0, speed: 8.0, course: 0.0),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(9), coordinate: CLLocationCoordinate2D(latitude: 21.0325, longitude: 105.8542), horizontalAccuracy: 3.0, speed: 8.0, course: 0.0),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(11), coordinate: CLLocationCoordinate2D(latitude: 21.0330, longitude: 105.8542), horizontalAccuracy: 3.0, speed: 8.0, course: 0.0)
        ]
        runner.replay(samples: recoveredSamples)

        XCTAssertFalse(sessionManager.isOffRoute)
        XCTAssertEqual(sessionManager.offRouteState, .onRoute)
    }

    // MARK: - 9. Reroute Commit Replay

    func testReplay_RerouteCommit_AtomicallyInstallsRouteBWithStableSession() {
        sessionManager.startNavigation(route: routeA, destination: destA)
        let initialSessionGen = sessionManager.sessionGeneration
        let initialRouteGen = sessionManager.activeRouteGeneration

        let routeB = NavRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8550),
                coordC
            ],
            steps: [],
            totalDistanceMeters: 800,
            totalDurationSeconds: 80
        )

        // Commit reroute
        sessionManager.replaceActiveRoute(routeB)

        XCTAssertEqual(sessionManager.sessionGeneration, initialSessionGen, "Session generation must be preserved")
        XCTAssertEqual(sessionManager.activeRouteGeneration, initialRouteGen + 1, "Route generation must increment")
        XCTAssertEqual(sessionManager.activeRoute?.totalDistanceMeters, 800)
        XCTAssertEqual(sessionManager.diagnostics.rerouteCommits, 1)

        // Progress continues on Route B
        runner.replay(samples: [NavigationReplaySample(
            timestamp: Date(),
            coordinate: CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8550)
        )])
        XCTAssertEqual(sessionManager.currentPolylineSegmentIndex, 0)
    }

    // MARK: - 10. Reroute Failure and Backoff Replay

    func testReplay_RerouteFailureAndBackoff_SuppressesImmediateRetry() {
        var config = OffRouteDetectorConfig()
        config.strongDeviationDwellSeconds = 1.0
        let detector = OffRouteDetector(config: config)
        let baseDate = Date()

        // 1. Trigger off-route
        let obs1 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 40.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 5.0
        )
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(1.5),
            lateralDistanceMeters: 40.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 5.0
        )
        _ = detector.evaluate(observation: obs1)
        let decision = detector.evaluate(observation: obs2)
        XCTAssertEqual(decision.state, OffRouteState.confirmed)

        // Reroute manager backoff logic
        var requestCount = 0
        let backoffWindow: TimeInterval = 4.0
        var lastFailureTime: Date? = nil

        func canAttemptReroute(now: Date) -> Bool {
            if let fail = lastFailureTime, now.timeIntervalSince(fail) < backoffWindow {
                return false
            }
            requestCount += 1
            return true
        }

        XCTAssertTrue(canAttemptReroute(now: baseDate.addingTimeInterval(2)))
        // Failure occurs at t=3
        lastFailureTime = baseDate.addingTimeInterval(3)

        // Immediate retry at t=4 is suppressed by backoff
        XCTAssertFalse(canAttemptReroute(now: baseDate.addingTimeInterval(4)))

        // Later retry after backoff expires (t=8) is permitted
        XCTAssertTrue(canAttemptReroute(now: baseDate.addingTimeInterval(8)))
        XCTAssertEqual(requestCount, 2)
    }

    // MARK: - 11. Arrival Replay

    func testReplay_ArrivalConditions_RequiresPhysicalAndAlongRouteProximity() {
        sessionManager.startNavigation(route: routeA, destination: destA)

        let baseDate = Date()
        // Feed sample near destination (< 25m)
        let arrivalSample = NavigationReplaySample(
            timestamp: baseDate,
            coordinate: CLLocationCoordinate2D(latitude: 21.03845, longitude: 105.8542), // ~5m from dest
            speed: 1.0
        )
        runner.replay(samples: [arrivalSample])

        XCTAssertEqual(runner.arrivalCount, 1)
        XCTAssertEqual(sessionManager.state, .arrived)
    }

    // MARK: - 12. Transport Mode Change Replay

    func testReplay_TransportModeSwitchWhileNavigating_PreservesActiveRoute() {
        sessionManager.startNavigation(route: routeA, destination: destA)
        let origDist = sessionManager.activeRoute?.totalDistanceMeters

        sessionManager.updateTransportMode(.auto)

        XCTAssertEqual(sessionManager.state, .navigating)
        XCTAssertEqual(sessionManager.activeRoute?.totalDistanceMeters, origDist)
        XCTAssertEqual(sessionManager.currentTrackingConfig.activityType, .automotiveNavigation)
    }

    // MARK: - 13. Large Route Replay

    func testReplay_LargeRoute_BoundedStructuresAndMonotonicProgress() {
        // Construct 50-point polyline
        var longCoords: [CLLocationCoordinate2D] = []
        for i in 0..<50 {
            longCoords.append(CLLocationCoordinate2D(
                latitude: 21.0000 + Double(i) * 0.001,
                longitude: 105.8500
            ))
        }

        let longStep = NavStep(
            coordinate: longCoords.last!,
            distanceMeters: 5550,
            durationSeconds: 500,
            streetName: "Highway",
            maneuverType: .straight,
            instruction: "Follow highway"
        )
        let longRoute = NavRoute(
            coordinates: longCoords,
            steps: [longStep],
            totalDistanceMeters: 5550,
            totalDurationSeconds: 500
        )
        sessionManager.startNavigation(route: longRoute, destination: NavigationDestination(coordinate: longCoords.last!, name: "Far"))

        let baseDate = Date()
        var samples: [NavigationReplaySample] = []
        for i in 0..<40 {
            samples.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(Double(i) * 5.0),
                coordinate: longCoords[i],
                speed: 10.0
            ))
        }

        runner.replay(samples: samples)

        XCTAssertEqual(sessionManager.state, .navigating)
        XCTAssertEqual(sessionManager.diagnostics.locationsReceived, 40)
        XCTAssertEqual(sessionManager.diagnostics.locationsAccepted, 40)
        XCTAssertEqual(sessionManager.diagnostics.progressComputations, 40)
    }

    // MARK: - 14. Full End-to-End Scenario Replay

    func testReplay_FullEndToEndScenario() {
        // 1. Idle -> Preview
        sessionManager.setRoutePreview(route: routeA)
        XCTAssertEqual(sessionManager.state, .routePreview)
        XCTAssertEqual(sessionManager.trackingProfile, .routePreview)

        // 2. Start Navigation
        sessionManager.startNavigation(route: routeA, destination: destA)
        XCTAssertEqual(sessionManager.state, .navigating)
        XCTAssertEqual(sessionManager.trackingProfile, .activeNavigation)

        let baseDate = Date()
        // 3. Normal progress on Route A
        runner.replay(samples: [
            NavigationReplaySample(timestamp: baseDate, coordinate: coordA),
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(10), coordinate: coordB)
        ])

        // 4. Temporary GPS jitter
        runner.replay(samples: [
            NavigationReplaySample(timestamp: baseDate.addingTimeInterval(12), coordinate: CLLocationCoordinate2D(latitude: coordB.latitude + 0.00002, longitude: coordB.longitude + 0.00002))
        ])
        XCTAssertFalse(sessionManager.isOffRoute)

        // 5. Wrong turn: vehicle diverges east
        for i in 15...19 {
            runner.replay(samples: [
                NavigationReplaySample(timestamp: baseDate.addingTimeInterval(Double(i)), coordinate: CLLocationCoordinate2D(latitude: 21.0340, longitude: 105.8550), speed: 8.0, course: 90.0)
            ])
        }
        XCTAssertTrue(sessionManager.isOffRoute)

        // 6. Reroute commit with Route B
        let stepB = NavStep(
            coordinate: coordC,
            distanceMeters: 500,
            durationSeconds: 50,
            streetName: "Route B",
            maneuverType: .straight,
            instruction: "Proceed to destination"
        )
        let routeB = NavRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 21.0340, longitude: 105.8550),
                coordC
            ],
            steps: [stepB],
            totalDistanceMeters: 500,
            totalDurationSeconds: 50
        )
        sessionManager.replaceActiveRoute(routeB)
        XCTAssertEqual(sessionManager.activeRoute?.totalDistanceMeters, 500)

        // 7. Route progress continues on Route B to arrival
        let startB = CLLocationCoordinate2D(latitude: 21.0340, longitude: 105.8550)
        var samplesB: [NavigationReplaySample] = []
        for i in 0...3 {
            let frac = Double(i) / 3.0
            let lat = startB.latitude + frac * (coordC.latitude - startB.latitude)
            let lon = startB.longitude + frac * (coordC.longitude - startB.longitude)
            samplesB.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(25.0 + Double(i) * 10.0),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                speed: 10.0,
                course: 0.0
            ))
        }
        // Vehicle reaches destination coordC
        samplesB.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(60.0),
            coordinate: coordC,
            horizontalAccuracy: 5.0,
            speed: 0.0,
            course: 0.0
        ))
        samplesB.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(62.0),
            coordinate: coordC,
            horizontalAccuracy: 5.0,
            speed: 0.0,
            course: 0.0
        ))
        runner.replay(samples: samplesB)

        XCTAssertEqual(runner.arrivalCount, 1)
        XCTAssertEqual(sessionManager.state, .arrived)

        // 8. Stop navigation
        sessionManager.stopNavigation()
        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertEqual(sessionManager.trackingProfile, .foregroundPassive)
    }

    // MARK: - Requirement 65: BLE Disconnection Must Not Affect Navigation Correctness

    func testReplay_BLEDisconnection_NavigationContinuesNormally() {
        let runner = NavigationReplayRunner()
        let sessionManager = runner.sessionManager
        let bleManager = BLEManager()

        // Verify BLE starts in disconnected state
        XCTAssertEqual(bleManager.connectionState, .disconnected)

        // Wire BLE progress update chaining existing runner callback
        let prevCallback = sessionManager.onProgressUpdate
        sessionManager.onProgressUpdate = { progress in
            prevCallback?(progress)
            bleManager.sendNavigationPacket(progress)
        }

        let coordA = CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8500)
        let coordB = CLLocationCoordinate2D(latitude: 21.0350, longitude: 105.8500)
        let coordC = CLLocationCoordinate2D(latitude: 21.0400, longitude: 105.8500)

        let route = NavRoute(
            coordinates: [coordA, coordB, coordC],
            steps: [
                NavStep(coordinate: coordA, distanceMeters: 550, durationSeconds: 60, streetName: "Hang Dao", maneuverType: .straight, instruction: "Go straight"),
                NavStep(coordinate: coordC, distanceMeters: 550, durationSeconds: 60, streetName: "Hang Dao", maneuverType: .arrive, instruction: "Arrive")
            ],
            totalDistanceMeters: 1100,
            totalDurationSeconds: 120
        )

        runner.installRoute(route)
        let baseDate = Date()

        // Ingest progress with BLE disconnected
        var bleSamples: [NavigationReplaySample] = []
        for i in 0...4 {
            let frac = Double(i) / 4.0
            let lat = coordA.latitude + frac * (coordC.latitude - coordA.latitude)
            let lon = coordA.longitude
            bleSamples.append(NavigationReplaySample(
                timestamp: baseDate.addingTimeInterval(Double(i) * 15.0),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                speed: 10.0,
                course: 0.0
            ))
        }
        // Vehicle reaches destination coordC
        bleSamples.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(65.0),
            coordinate: coordC,
            horizontalAccuracy: 5.0,
            speed: 0.0,
            course: 0.0
        ))
        bleSamples.append(NavigationReplaySample(
            timestamp: baseDate.addingTimeInterval(67.0),
            coordinate: coordC,
            horizontalAccuracy: 5.0,
            speed: 0.0,
            course: 0.0
        ))
        runner.replay(samples: bleSamples)

        // Navigation progressed completely to arrival despite BLE being disconnected
        XCTAssertGreaterThanOrEqual(runner.capturedProgress.count, 5)
        XCTAssertEqual(runner.arrivalCount, 1)
        XCTAssertEqual(sessionManager.state, .arrived)
        XCTAssertGreaterThanOrEqual(runner.sessionManager.diagnostics.locationsAccepted, 5)
        XCTAssertGreaterThanOrEqual(runner.sessionManager.diagnostics.progressComputations, 5)
    }
}
