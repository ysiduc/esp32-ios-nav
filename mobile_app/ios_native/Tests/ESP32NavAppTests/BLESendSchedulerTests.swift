//
//  BLESendSchedulerTests.swift
//  Unit tests for BLE send scheduler, deduplication, 5Hz rate limit, and flow control.
//

import CoreBluetooth
import XCTest
@testable import ESP32NavApp

@MainActor
final class BLESendSchedulerTests: XCTestCase {

    private var scheduler: BLESendScheduler!

    override func setUp() {
        super.setUp()
        scheduler = BLESendScheduler(minSendInterval: 0.2) // 5 Hz
    }

    override func tearDown() {
        scheduler = nil
        super.tearDown()
    }

    func testDuplicatePacketSuppression() {
        let baseDate = Date()
        let progress = NavigationProgress(
            maneuver: .straight,
            distanceToTurnMeters: 200,
            remainingDistanceMeters: 1000,
            remainingEtaSeconds: 100,
            currentSpeedKmh: 36,
            speedLimitKmh: 50,
            nextStreetName: "Trần Hưng Đạo"
        )

        let action1 = scheduler.schedule(
            progress: progress,
            writeType: .withoutResponse,
            canSendWithoutResponse: true,
            now: baseDate
        )
        if case .send = action1 {} else {
            XCTFail("First packet must be sent")
        }

        // Send identical packet 1.0s later
        let action2 = scheduler.schedule(
            progress: progress,
            writeType: .withoutResponse,
            canSendWithoutResponse: true,
            now: baseDate.addingTimeInterval(1.0)
        )
        XCTAssertEqual(action2, .suppressedDuplicate)
        XCTAssertEqual(scheduler.duplicatesSuppressed, 1)
    }

    func testRateLimitCap_5Hz() {
        let baseDate = Date()
        let p1 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 500, remainingDistanceMeters: 1000, remainingEtaSeconds: 100, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "A")
        let p2 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 490, remainingDistanceMeters: 990, remainingEtaSeconds: 99, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "A")

        let action1 = scheduler.schedule(progress: p1, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate)
        if case .send = action1 {} else { XCTFail("First packet must send") }

        // Second packet arrives 0.05s later (< 0.2s)
        let action2 = scheduler.schedule(progress: p2, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate.addingTimeInterval(0.05))
        XCTAssertEqual(action2, .queuedRateLimited)
        XCTAssertNotNil(scheduler.pendingPacket)

        // At t=0.25s, timer fires and flushes p2
        let flushed = scheduler.rateLimitTimerFired(now: baseDate.addingTimeInterval(0.25))
        XCTAssertNotNil(flushed)
        XCTAssertNil(scheduler.pendingPacket)
    }

    func testCoalescing_ReplacesOlderPendingWithNewest() {
        let baseDate = Date()
        let p1 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 500, remainingDistanceMeters: 1000, remainingEtaSeconds: 100, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "A")
        _ = scheduler.schedule(progress: p1, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate)

        // Rapid stream while rate-limited: p2, p3, p4
        for i in 1...3 {
            let p = NavigationProgress(maneuver: .straight, distanceToTurnMeters: UInt32(500 - i * 5), remainingDistanceMeters: UInt32(1000 - i * 5), remainingEtaSeconds: 90, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "A")
            _ = scheduler.schedule(progress: p, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate.addingTimeInterval(Double(i) * 0.03))
        }

        XCTAssertEqual(scheduler.packetsCoalesced, 2, "Should have coalesced 2 older pending packets")
        XCTAssertNotNil(scheduler.pendingPacket)
        // Pending packet should be the latest (p4: distanceToTurn = 485)
        XCTAssertEqual(scheduler.pendingPacket?.progress.distanceToTurnMeters, 485)
    }

    func testTransportBackpressure_WithoutResponse() {
        let baseDate = Date()
        let progress = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 300, remainingDistanceMeters: 800, remainingEtaSeconds: 80, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "B")

        // Peripheral buffer full: canSendWithoutResponse == false
        let action = scheduler.schedule(progress: progress, writeType: .withoutResponse, canSendWithoutResponse: false, now: baseDate)
        XCTAssertEqual(action, .queuedBackpressure)
        XCTAssertFalse(scheduler.isTransportReady)
        XCTAssertNotNil(scheduler.pendingPacket)

        // Transport signals readiness
        let flushed = scheduler.transportBecameReady(now: baseDate.addingTimeInterval(0.1))
        XCTAssertNotNil(flushed)
        XCTAssertTrue(scheduler.isTransportReady)
        XCTAssertNil(scheduler.pendingPacket)
    }

    func testUrgentManeuverChange_BypassesDuplicateSuppression() {
        let baseDate = Date()
        let p1 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 100, remainingDistanceMeters: 500, remainingEtaSeconds: 50, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "C")
        let p2 = NavigationProgress(maneuver: .left, distanceToTurnMeters: 100, remainingDistanceMeters: 500, remainingEtaSeconds: 50, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "C")

        let a1 = scheduler.schedule(progress: p1, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate)
        if case .send = a1 {} else { XCTFail() }

        // Maneuver changes: must send immediately regardless of timing
        let a2 = scheduler.schedule(progress: p2, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate.addingTimeInterval(0.01))
        if case .send = a2 {} else { XCTFail("Urgent maneuver change must send immediately") }
    }

    func testUrgentArrival_BypassesRateLimiting() {
        let baseDate = Date()
        let p1 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 50, remainingDistanceMeters: 50, remainingEtaSeconds: 5, currentSpeedKmh: 10, speedLimitKmh: 0, nextStreetName: "D")
        let pArrive = NavigationProgress(maneuver: .arrive, distanceToTurnMeters: 0, remainingDistanceMeters: 0, remainingEtaSeconds: 0, currentSpeedKmh: 0, speedLimitKmh: 0, nextStreetName: "Đã đến nơi")

        _ = scheduler.schedule(progress: p1, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate)

        // Arrival 0.05s later must send immediately
        let action = scheduler.schedule(progress: pArrive, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate.addingTimeInterval(0.05))
        if case .send = action {} else {
            XCTFail("Arrival must bypass rate limiting")
        }
    }

    func testWithResponseFlowControl() {
        let baseDate = Date()
        let p1 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 400, remainingDistanceMeters: 1000, remainingEtaSeconds: 100, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "E")
        let p2 = NavigationProgress(maneuver: .straight, distanceToTurnMeters: 380, remainingDistanceMeters: 980, remainingEtaSeconds: 98, currentSpeedKmh: 30, speedLimitKmh: 0, nextStreetName: "E")

        let a1 = scheduler.schedule(progress: p1, writeType: .withResponse, canSendWithoutResponse: true, now: baseDate)
        if case .send = a1 {} else { XCTFail() }
        XCTAssertTrue(scheduler.inFlightWithResponseWrite)

        // Second write while write 1 is in-flight
        let a2 = scheduler.schedule(progress: p2, writeType: .withResponse, canSendWithoutResponse: true, now: baseDate.addingTimeInterval(0.5))
        XCTAssertEqual(a2, .queuedBackpressure)

        // Peripheral ACK received
        let flushed = scheduler.withResponseWriteCompleted(now: baseDate.addingTimeInterval(0.6))
        XCTAssertNotNil(flushed)
        XCTAssertTrue(scheduler.inFlightWithResponseWrite)
        XCTAssertNil(scheduler.pendingPacket)
    }
}
