//
//  BLEScanGenerationTests.swift
//  P5.1 test: BLEScanGenerationGuard production helper unit tests.
//  Directly tests the pure production guard that protects BLEManager against
//  stale delayed fallback scan closures executing across scan lifecycle transitions.
//

import XCTest
@testable import ESP32NavApp

final class BLEScanGenerationTests: XCTestCase {

    func testBLEScanGenerationGuard_BeginIncrementsGenerationAndValidatesToken() {
        var guardHelper = BLEScanGenerationGuard()
        XCTAssertEqual(guardHelper.generation, 0)

        let token1 = guardHelper.begin()
        XCTAssertEqual(token1, 1)
        XCTAssertEqual(guardHelper.generation, 1)
        XCTAssertTrue(guardHelper.isCurrent(token1), "Token 1 must be current for active session 1")

        let token2 = guardHelper.begin()
        XCTAssertEqual(token2, 2)
        XCTAssertEqual(guardHelper.generation, 2)
        XCTAssertTrue(guardHelper.isCurrent(token2), "Token 2 must be current for active session 2")
        XCTAssertFalse(guardHelper.isCurrent(token1), "Token 1 must no longer be current after session 2 begins")
    }

    func testBLEScanGenerationGuard_InvalidateCancelsCurrentToken() {
        var guardHelper = BLEScanGenerationGuard()
        let token = guardHelper.begin()
        XCTAssertTrue(guardHelper.isCurrent(token))

        guardHelper.invalidate()
        XCTAssertFalse(guardHelper.isCurrent(token), "Invalidation (e.g. stopScanning) must invalidate active token")
    }

    func testBLEScanGenerationGuard_StaleClosureSimulation() {
        var guardHelper = BLEScanGenerationGuard()

        // Session 1 starts, capturing token1
        let token1 = guardHelper.begin()

        // Before session 1 callback executes, scan is stopped
        guardHelper.invalidate()

        // When session 1 fallback fires, isCurrent check must reject it
        XCTAssertFalse(guardHelper.isCurrent(token1), "Stale fallback closure must be rejected after stop")

        // Session 2 starts
        let token2 = guardHelper.begin()
        XCTAssertTrue(guardHelper.isCurrent(token2))
        XCTAssertFalse(guardHelper.isCurrent(token1), "Stale session 1 callback must still be rejected in session 2")
    }

    func testBLEScanGenerationGuard_MonotonicallyIncrementing() {
        var guardHelper = BLEScanGenerationGuard()
        let initial = guardHelper.generation

        let g1 = guardHelper.begin()
        guardHelper.invalidate()
        let g2 = guardHelper.generation
        let g3 = guardHelper.begin()

        XCTAssertGreaterThan(g1, initial)
        XCTAssertGreaterThan(g2, g1)
        XCTAssertGreaterThan(g3, g2)
    }

    @MainActor
    func testBLEManager_WiresProductionScanGuard() {
        let manager = BLEManager()
        let genBefore = manager.scanGeneration
        XCTAssertEqual(genBefore, manager.scanGuard.generation)
    }
}
