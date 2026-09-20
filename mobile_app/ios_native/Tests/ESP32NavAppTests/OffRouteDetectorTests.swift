//
//  OffRouteDetectorTests.swift
//  Deterministic unit tests for quality-aware OffRouteDetector state machine.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

final class OffRouteDetectorTests: XCTestCase {

    var detector: OffRouteDetector!
    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    override func setUp() {
        super.setUp()
        detector = OffRouteDetector()
    }

    // MARK: - Test 1: Normal On-Route Driving

    func testNormalOnRouteDriving() {
        let obs = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 3.5,
            horizontalAccuracyMeters: 4.0,
            speedMetersPerSecond: 12.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 90.0,
            distanceAlongRouteMeters: 100.0
        )

        let decision = detector.evaluate(observation: obs)
        XCTAssertEqual(decision.state, .onRoute)
        XCTAssertFalse(decision.becameConfirmed)
        XCTAssertFalse(decision.recovered)
        XCTAssertEqual(decision.reason, .none)
    }

    // MARK: - Test 2: Brief GPS Spike Recovers Without Confirmation

    func testBriefGPSSpikeRecoversWithoutConfirmation() {
        // Sample 1: On-route
        let obs1 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 2.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        XCTAssertEqual(detector.evaluate(observation: obs1).state, .onRoute)

        // Sample 2: Sudden 35m GPS spike (dt = 1s)
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(1.0),
            lateralDistanceMeters: 35.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .suspected)
        XCTAssertFalse(dec2.becameConfirmed)

        // Sample 3: Back on route at 3m (dt = 2s)
        let obs3 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(2.0),
            lateralDistanceMeters: 3.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let dec3 = detector.evaluate(observation: obs3)
        XCTAssertEqual(dec3.state, .onRoute)
        XCTAssertFalse(dec3.becameConfirmed)
        XCTAssertTrue(dec3.recovered)
        XCTAssertEqual(dec3.reason, .recoveredToRoute)
    }

    // MARK: - Test 3: Sustained Real Deviation Confirms

    func testSustainedRealDeviationConfirms() {
        // t = 0s: Enters suspected state (lateral 18m > 15m base threshold)
        let obs1 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 18.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let dec1 = detector.evaluate(observation: obs1)
        XCTAssertEqual(dec1.state, .suspected)
        XCTAssertFalse(dec1.becameConfirmed)

        // t = 1.0s: Still suspected (1.0s < standard dwell 2.5s)
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(1.0),
            lateralDistanceMeters: 20.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .suspected)
        XCTAssertFalse(dec2.becameConfirmed)

        // t = 2.6s: Elapsed 2.6s >= 2.5s -> CONFIRMED!
        let obs3 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(2.6),
            lateralDistanceMeters: 22.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let dec3 = detector.evaluate(observation: obs3)
        XCTAssertEqual(dec3.state, .confirmed)
        XCTAssertTrue(dec3.becameConfirmed)
        XCTAssertEqual(dec3.reason, .sustainedLateralDeviation)
    }

    // MARK: - Test 4: Low-Quality Accepted GPS Dynamic Threshold Scaling

    func testLowQualityAcceptedGPSDynamicThresholdScaling() {
        // Borderline GPS accuracy = 18.0m (below max 20m)
        // Scaled threshold: max(15.0, 18.0 * 1.2) = 21.6m
        let obs = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 17.0,
            horizontalAccuracyMeters: 18.0,
            speedMetersPerSecond: 10.0
        )

        let dec = detector.evaluate(observation: obs)
        // 17.0m is below the scaled threshold of 21.6m, so it remains onRoute!
        XCTAssertEqual(dec.state, .onRoute)
        XCTAssertEqual(dec.activeThresholdMeters, 21.6, accuracy: 0.01)
    }

    // MARK: - Test 5: Stationary GPS Drift Requires Longer Dwell (5.0s)

    func testStationaryGPSDriftRequiresLongerDwell() {
        // Vehicle stopped at red light (speed = 0.5 m/s < 3.0 m/s), GPS drifts to 18m
        let obs1 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 18.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 0.5
        )
        XCTAssertEqual(detector.evaluate(observation: obs1).state, .suspected)

        // At t = 3.0s: A moving vehicle would have confirmed (2.5s), but stationary requires 5.0s!
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(3.0),
            lateralDistanceMeters: 18.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 0.5
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .suspected, "Stationary GPS jitter must not trigger premature reroute")
        XCTAssertFalse(dec2.becameConfirmed)

        // At t = 5.2s: Dwell reaches 5.2s >= 5.0s -> Confirmed
        let obs3 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(5.2),
            lateralDistanceMeters: 19.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 0.5
        )
        let dec3 = detector.evaluate(observation: obs3)
        XCTAssertEqual(dec3.state, .confirmed)
        XCTAssertTrue(dec3.becameConfirmed)
        XCTAssertEqual(dec3.reason, .lowSpeedDriftDwell)
    }

    // MARK: - Test 6: Course Divergence Accelerates Confirmation (1.5s)

    func testCourseDivergenceAcceleratesConfirmation() {
        // Vehicle driving East (90 deg) while route goes North (0 deg) -> 90 deg divergence >= 45 deg
        let obs1 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 18.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 0.0
        )
        XCTAssertEqual(detector.evaluate(observation: obs1).state, .suspected)

        // At t = 1.6s (>= 1.5s course divergence dwell) -> Confirmed faster than 2.5s standard
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(1.6),
            lateralDistanceMeters: 22.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0,
            courseDegrees: 90.0,
            routeBearingDegrees: 0.0
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .confirmed)
        XCTAssertTrue(dec2.becameConfirmed)
        XCTAssertEqual(dec2.reason, .courseDivergence)
    }

    // MARK: - Test 7: Hysteresis Prevents State Flapping Around Threshold

    func testHysteresisPreventsStateFlapping() {
        // Transition to confirmed
        _ = detector.evaluate(observation: OffRouteObservation(timestamp: baseDate, lateralDistanceMeters: 20.0, horizontalAccuracyMeters: 5.0, speedMetersPerSecond: 10.0))
        _ = detector.evaluate(observation: OffRouteObservation(timestamp: baseDate.addingTimeInterval(2.6), lateralDistanceMeters: 20.0, horizontalAccuracyMeters: 5.0, speedMetersPerSecond: 10.0))
        XCTAssertEqual(detector.state, .confirmed)

        // Lateral distance drops to 14m (below enter threshold 15m, but above recovery threshold 10m)
        let obsOsc = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(3.0),
            lateralDistanceMeters: 14.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let decOsc = detector.evaluate(observation: obsOsc)
        // Remains confirmed! Does NOT oscillate back and forth between onRoute and confirmed!
        XCTAssertEqual(decOsc.state, .confirmed)
        XCTAssertFalse(decOsc.recovered)
    }

    // MARK: - Test 8: Sustained Recovery Drops Below Lower Hysteresis Threshold

    func testSustainedRecoveryDropsBelowLowerHysteresisThreshold() {
        // Set confirmed state
        _ = detector.evaluate(observation: OffRouteObservation(timestamp: baseDate, lateralDistanceMeters: 20.0, horizontalAccuracyMeters: 5.0, speedMetersPerSecond: 10.0))
        _ = detector.evaluate(observation: OffRouteObservation(timestamp: baseDate.addingTimeInterval(2.6), lateralDistanceMeters: 20.0, horizontalAccuracyMeters: 5.0, speedMetersPerSecond: 10.0))
        XCTAssertEqual(detector.state, .confirmed)

        // t = 4.0s: Drops to 5m (below recovery threshold 10m)
        let obsRec1 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(4.0),
            lateralDistanceMeters: 5.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let decRec1 = detector.evaluate(observation: obsRec1)
        XCTAssertEqual(decRec1.state, .confirmed, "Requires recovery dwell before confirming return to route")

        // t = 5.2s: Dwells below recovery threshold for 1.2s >= 1.0s -> onRoute!
        let obsRec2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(5.2),
            lateralDistanceMeters: 5.0,
            horizontalAccuracyMeters: 5.0,
            speedMetersPerSecond: 10.0
        )
        let decRec2 = detector.evaluate(observation: obsRec2)
        XCTAssertEqual(decRec2.state, .onRoute)
        XCTAssertTrue(decRec2.recovered)
        XCTAssertEqual(decRec2.reason, .recoveredToRoute)
    }

    // MARK: - Test 9: Strong Deviation Fast Track (1.0s Dwell)

    func testStrongDeviationFastTrack() {
        // Large deviation: 45m with good GPS (accuracy 8m <= 15m)
        let obs1 = OffRouteObservation(
            timestamp: baseDate,
            lateralDistanceMeters: 45.0,
            horizontalAccuracyMeters: 8.0,
            speedMetersPerSecond: 10.0
        )
        XCTAssertEqual(detector.evaluate(observation: obs1).state, .suspected)

        // At t = 1.1s (>= 1.0s strong deviation dwell) -> Confirmed
        let obs2 = OffRouteObservation(
            timestamp: baseDate.addingTimeInterval(1.1),
            lateralDistanceMeters: 46.0,
            horizontalAccuracyMeters: 8.0,
            speedMetersPerSecond: 10.0
        )
        let dec2 = detector.evaluate(observation: obs2)
        XCTAssertEqual(dec2.state, .confirmed)
        XCTAssertTrue(dec2.becameConfirmed)
        XCTAssertEqual(dec2.reason, .strongLateralDeviation)
    }

    // MARK: - Test 10: Reset Clears All Detector State

    func testResetClearsAllDetectorState() {
        _ = detector.evaluate(observation: OffRouteObservation(timestamp: baseDate, lateralDistanceMeters: 50.0, horizontalAccuracyMeters: 5.0, speedMetersPerSecond: 10.0))
        _ = detector.evaluate(observation: OffRouteObservation(timestamp: baseDate.addingTimeInterval(1.5), lateralDistanceMeters: 50.0, horizontalAccuracyMeters: 5.0, speedMetersPerSecond: 10.0))
        XCTAssertEqual(detector.state, .confirmed)

        detector.reset()
        XCTAssertEqual(detector.state, .onRoute)
        XCTAssertNil(detector.suspectStartedAt)
        XCTAssertNil(detector.recoveryStartedAt)
        XCTAssertNil(detector.lastObservationTimestamp)
    }
}
