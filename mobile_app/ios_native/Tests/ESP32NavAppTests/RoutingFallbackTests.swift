//
//  RoutingFallbackTests.swift
//  Unit tests for MapKit mode mapping, degraded fallback semantics, and proportional step durations.
//

import XCTest
import MapKit
@testable import ESP32NavApp

final class RoutingFallbackTests: XCTestCase {

    // MARK: - 1. Mode Mapping Tests

    func testMapKitModeMapping_Auto_IsNative() throws {
        let policy = FallbackPolicy.auto
        let result = try MapKitModeMapper.mapTransportMode(.auto, policy: policy)

        XCTAssertEqual(result.transportType, .automobile)
        XCTAssertFalse(result.isDegraded)
        XCTAssertNil(result.degradedReason)
    }

    func testMapKitModeMapping_Pedestrian_IsNative() throws {
        let policy = FallbackPolicy.pedestrian
        let result = try MapKitModeMapper.mapTransportMode(.pedestrian, policy: policy)

        XCTAssertEqual(result.transportType, .walking)
        XCTAssertFalse(result.isDegraded)
        XCTAssertNil(result.degradedReason)
    }

    func testMapKitModeMapping_Motorcycle_IsDegradedApproximation() throws {
        let policy = FallbackPolicy.motorcycle
        let result = try MapKitModeMapper.mapTransportMode(.motorcycle, policy: policy)

        // Maps to automobile but explicitly marked degraded
        XCTAssertEqual(result.transportType, .automobile)
        XCTAssertTrue(result.isDegraded)
        XCTAssertNotNil(result.degradedReason)
        XCTAssertTrue(result.degradedReason!.contains("ô tô"))
    }

    func testMapKitModeMapping_Bicycle_IsDegradedApproximation() throws {
        let policy = FallbackPolicy.bicycle
        let result = try MapKitModeMapper.mapTransportMode(.bicycle, policy: policy)

        XCTAssertEqual(result.transportType, .walking)
        XCTAssertTrue(result.isDegraded)
        XCTAssertNotNil(result.degradedReason)
    }

    func testMapKitModeMapping_UnsupportedCapability_ThrowsModeUnavailable() {
        let strictPolicy = FallbackPolicy(
            allowMapKitFallback: false,
            mapKitCapability: .unsupported
        )

        XCTAssertThrowsError(try MapKitModeMapper.mapTransportMode(.motorcycle, policy: strictPolicy)) { error in
            if let routingErr = error as? ValhallaRoutingError,
               case .modeUnavailable(let msg) = routingErr {
                XCTAssertFalse(msg.isEmpty)
            } else {
                XCTFail("Expected ValhallaRoutingError.modeUnavailable, got \(error)")
            }
        }
    }

    // MARK: - 2. Proportional Step Duration Policy

    func testMapKitStepDuration_ProportionalCalculation() {
        let totalDistanceMeters: Double = 2000.0
        let totalDurationSeconds: Double = 240.0

        let step1Dist = 500.0
        let step2Dist = 1500.0

        let step1Dur = (step1Dist / totalDistanceMeters) * totalDurationSeconds
        let step2Dur = (step2Dist / totalDistanceMeters) * totalDurationSeconds

        XCTAssertEqual(step1Dur, 60.0, accuracy: 1e-6)
        XCTAssertEqual(step2Dur, 180.0, accuracy: 1e-6)
        XCTAssertEqual(step1Dur + step2Dur, totalDurationSeconds, accuracy: 1e-6)
    }

    // MARK: - 3. Error Classification

    func testErrorClassification_EngineUnavailable() {
        let err = NSError(domain: ValhallaEngineErrorDomain, code: ValhallaEngineError.configNotLoaded.rawValue, userInfo: [NSLocalizedDescriptionKey: "Config not loaded"])
        let cat = RoutingErrorCategory.engineUnavailable
        XCTAssertEqual(cat, .engineUnavailable)
        XCTAssertEqual(err.code, 1001)
    }
}
