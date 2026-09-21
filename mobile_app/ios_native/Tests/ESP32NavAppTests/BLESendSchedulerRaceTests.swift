//
//  BLESendSchedulerRaceTests.swift
//  P5.1 tests: BLE backpressure race — pending packets must not be permanently stranded
//  when the transport becomes ready or ACK fires while the rate-limit window has not elapsed.
//

import XCTest
import CoreBluetooth
@testable import ESP32NavApp

@MainActor
final class BLESendSchedulerRaceTests: XCTestCase {

    var scheduler: BLESendScheduler!
    let baseDate = Date(timeIntervalSince1970: 1700000000.0)

    override func setUp() async throws {
        scheduler = BLESendScheduler(minSendInterval: 0.20)
    }

    override func tearDown() async throws {
        scheduler = nil
    }

    // Helper: a minimal NavigationProgress
    private func makeProgress(maneuver: ManeuverType = .straight, dist: UInt32 = 100) -> NavigationProgress {
        NavigationProgress(
            maneuver: maneuver,
            distanceToTurnMeters: dist,
            remainingDistanceMeters: dist,
            remainingEtaSeconds: 10,
            currentSpeedKmh: 30,
            speedLimitKmh: 50,
            nextStreetName: "Test Street"
        )
    }

    // MARK: - Fix 7: withoutResponse race

    /// When the transport becomes ready early (within the rate-limit window), the pending packet
    /// must not be permanently stranded. `nextEligibleFlushDelay` must return a non-nil delay
    /// so the caller can arm a timer.
    func testWithoutResponse_EarlyReadyCallback_PendingPacketDetectedAsRateLimited() {
        // 1. Send a first packet to prime lastSentTime
        let p1 = makeProgress(dist: 100)
        let action1 = scheduler.schedule(
            progress: p1,
            writeType: .withoutResponse,
            canSendWithoutResponse: true,
            now: baseDate
        )
        XCTAssertEqual(action1, .send(BLEPacket.serialize(progress: p1), .withoutResponse))

        // 2. Queue a second packet within the rate-limit window
        let p2 = makeProgress(dist: 90)
        let action2 = scheduler.schedule(
            progress: p2,
            writeType: .withoutResponse,
            canSendWithoutResponse: true,
            now: baseDate.addingTimeInterval(0.05) // 50ms < 200ms rate limit
        )
        XCTAssertEqual(action2, .queuedRateLimited, "Second packet in window must be rate-limited")
        XCTAssertNotNil(scheduler.pendingPacket, "Pending packet must be coalesced")

        // 3. Transport signals ready at 100ms — still within window
        let t100ms = baseDate.addingTimeInterval(0.10)
        let flushResult = scheduler.transportBecameReady(now: t100ms)
        XCTAssertNil(flushResult, "Flush must fail: still within rate-limit window")

        // 4. nextEligibleFlushDelay must return remaining delay (not nil),
        //    allowing the caller to arm a rate-limit timer
        let delay = scheduler.nextEligibleFlushDelay(now: t100ms)
        XCTAssertNotNil(delay, "Must expose remaining delay so caller can arm a flush timer")
        XCTAssertGreaterThan(delay!, 0)
        XCTAssertLessThanOrEqual(delay!, scheduler.minSendInterval)

        // 5. At 200ms the rate-limit expires — rateLimitTimerFired must flush the packet
        let t200ms = baseDate.addingTimeInterval(0.20)
        let timerFlush = scheduler.rateLimitTimerFired(now: t200ms)
        XCTAssertNotNil(timerFlush, "Rate-limit timer must flush the pending packet")
        XCTAssertNil(scheduler.pendingPacket, "Pending packet must be consumed on timer flush")
    }

    // MARK: - Fix 7: withResponse race

    /// When ACK arrives early, the pending packet must not be stranded.
    func testWithResponse_EarlyACK_PendingPacketDetectedAsRateLimited() {
        scheduler.isTransportReady = true
        scheduler.inFlightWithResponseWrite = false

        // 1. Send first withResponse packet
        let p1 = makeProgress(dist: 200)
        let action1 = scheduler.schedule(
            progress: p1,
            writeType: .withResponse,
            canSendWithoutResponse: false,
            now: baseDate
        )
        XCTAssertEqual(action1, .send(BLEPacket.serialize(progress: p1), .withResponse))
        XCTAssertTrue(scheduler.inFlightWithResponseWrite)

        // 2. Queue a second packet while write is in-flight
        let p2 = makeProgress(dist: 190)
        let action2 = scheduler.schedule(
            progress: p2,
            writeType: .withResponse,
            canSendWithoutResponse: false,
            now: baseDate.addingTimeInterval(0.05)
        )
        XCTAssertEqual(action2, .queuedBackpressure, "Must queue while write is in-flight")

        // 3. ACK arrives at 80ms — within rate-limit window; flush should fail
        let t80ms = baseDate.addingTimeInterval(0.08)
        let ackFlush = scheduler.withResponseWriteCompleted(now: t80ms)
        XCTAssertNil(ackFlush, "Must not flush within rate-limit window after ACK")

        // 4. nextEligibleFlushDelay must return non-nil so caller can arm timer
        let delay = scheduler.nextEligibleFlushDelay(now: t80ms)
        XCTAssertNotNil(delay, "Must expose delay for rate-limit timer arming after early ACK")

        // 5. Timer fires at 200ms — flush succeeds
        let timerFlush = scheduler.rateLimitTimerFired(now: baseDate.addingTimeInterval(0.20))
        XCTAssertNotNil(timerFlush, "Timer flush must deliver the pending packet")
    }

    // MARK: - Edge cases

    func testNextEligibleFlushDelay_NoPending_ReturnsNil() {
        XCTAssertNil(scheduler.nextEligibleFlushDelay(now: baseDate),
                     "No delay to report when no pending packet exists")
    }

    func testNextEligibleFlushDelay_PendingBlockedByFlowControl_ReturnsNil() {
        // Backpressure-blocked (transport not ready) — timer should not be armed
        scheduler.isTransportReady = false

        let p = makeProgress(dist: 50)
        _ = scheduler.schedule(progress: p, writeType: .withoutResponse,
                                canSendWithoutResponse: false, now: baseDate)

        XCTAssertNotNil(scheduler.pendingPacket)
        let delay = scheduler.nextEligibleFlushDelay(now: baseDate)
        XCTAssertNil(delay, "Flow-control blocked packet must not generate a rate-limit delay")
    }

    func testNextEligibleFlushDelay_PastWindow_ReturnsNil() {
        // Already past the rate-limit window — pending should flush immediately, not via timer
        let p1 = makeProgress(dist: 100)
        _ = scheduler.schedule(progress: p1, writeType: .withoutResponse,
                                canSendWithoutResponse: true, now: baseDate)
        let p2 = makeProgress(dist: 90)
        _ = scheduler.schedule(progress: p2, writeType: .withoutResponse,
                                canSendWithoutResponse: true,
                                now: baseDate.addingTimeInterval(0.05))

        // Check at t = 200ms (past window)
        let delay = scheduler.nextEligibleFlushDelay(now: baseDate.addingTimeInterval(0.20))
        XCTAssertNil(delay, "Past the window, flush is immediately eligible — no timer needed")
    }

    // MARK: - Fix 21 & 22: Shared Policy Early-Ready / Early-ACK Helper Tests

    func testHandleTransportBecameReady_EarlyReady_ArmsTimerWithRemainingDelay() {
        // 1. Send first packet at baseDate
        let p1 = makeProgress(dist: 100)
        _ = scheduler.schedule(progress: p1, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate)

        // 2. Queue second packet at t=50ms (rate-limited)
        let p2 = makeProgress(dist: 90)
        _ = scheduler.schedule(progress: p2, writeType: .withoutResponse, canSendWithoutResponse: true, now: baseDate.addingTimeInterval(0.05))

        // 3. Transport ready at t=100ms: early ready -> must arm timer with exactly 100ms remaining delay
        let t100ms = baseDate.addingTimeInterval(0.10)
        let action = scheduler.handleTransportBecameReady(now: t100ms)
        switch action {
        case .armTimer(let delay):
            XCTAssertGreaterThan(delay, 0.0)
            XCTAssertEqual(delay, 0.10, accuracy: 0.001, "Timer must be armed with actual remaining delay")
        default:
            XCTFail("Expected .armTimer but got \(action)")
        }

        // 4. At t=200ms, transport ready -> flushes immediately
        let t200ms = baseDate.addingTimeInterval(0.20)
        let actionAfterWindow = scheduler.handleTransportBecameReady(now: t200ms)
        switch actionAfterWindow {
        case .flush(let data, let writeType):
            XCTAssertEqual(data, BLEPacket.serialize(progress: p2))
            XCTAssertEqual(writeType, .withoutResponse)
        default:
            XCTFail("Expected .flush but got \(actionAfterWindow)")
        }
    }

    func testHandleWithResponseWriteCompleted_EarlyACK_ArmsTimerWithRemainingDelay() {
        scheduler.isTransportReady = true
        scheduler.inFlightWithResponseWrite = false

        // 1. Send first withResponse packet
        let p1 = makeProgress(dist: 200)
        _ = scheduler.schedule(progress: p1, writeType: .withResponse, canSendWithoutResponse: false, now: baseDate)

        // 2. Queue second packet at t=50ms
        let p2 = makeProgress(dist: 190)
        _ = scheduler.schedule(progress: p2, writeType: .withResponse, canSendWithoutResponse: false, now: baseDate.addingTimeInterval(0.05))

        // 3. Early ACK at t=80ms -> must arm timer with 120ms remaining delay
        let t80ms = baseDate.addingTimeInterval(0.08)
        let action = scheduler.handleWithResponseWriteCompleted(now: t80ms)
        switch action {
        case .armTimer(let delay):
            XCTAssertEqual(delay, 0.12, accuracy: 0.001, "Timer must be armed with remaining delay after early ACK")
        default:
            XCTFail("Expected .armTimer but got \(action)")
        }
    }
}
