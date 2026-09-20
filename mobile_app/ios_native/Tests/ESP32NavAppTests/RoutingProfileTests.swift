//
//  RoutingProfileTests.swift
//  Unit tests for strongly-typed transport modes, routing profiles, and structured JSON request building.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

final class RoutingProfileTests: XCTestCase {

    // MARK: - 1. Motorcycle Profile Specification

    func testMotorcycleProfile_DefaultsAndCostingOptions() {
        let profile = RoutingProfile.profile(for: .motorcycle)

        XCTAssertEqual(profile.id, "motorcycle_standard")
        XCTAssertEqual(profile.transportMode, .motorcycle)
        XCTAssertEqual(profile.valhallaCosting, "motorcycle")
        XCTAssertEqual(profile.maxAlternatives, 2)

        let opts = profile.costingOptions.numericOptions
        // Normal road navigation: no off-road tracks or trails
        XCTAssertEqual(opts["use_trails"], 0.0)
        XCTAssertEqual(opts["use_tracks"], 0.0)
        // Standard Vietnamese road navigation options
        XCTAssertEqual(opts["use_highways"], 0.5)
        XCTAssertEqual(opts["use_tolls"], 0.5)
        XCTAssertEqual(opts["use_ferry"], 0.5)
        XCTAssertEqual(opts["use_living_streets"], 0.5)

        // Fallback policy: MapKit allowed but marked degraded
        XCTAssertTrue(profile.fallbackPolicy.allowMapKitFallback)
        if case .degradedApproximation(let reason) = profile.fallbackPolicy.mapKitCapability {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("Expected degraded approximation capability for MapKit motorcycle fallback")
        }
    }

    // MARK: - 2. Auto Profile Specification

    func testAutoProfile_DefaultsAndCostingOptions() {
        let profile = RoutingProfile.profile(for: .auto)

        XCTAssertEqual(profile.id, "auto_standard")
        XCTAssertEqual(profile.transportMode, .auto)
        XCTAssertEqual(profile.valhallaCosting, "auto")
        XCTAssertEqual(profile.maxAlternatives, 2)

        let opts = profile.costingOptions.numericOptions
        XCTAssertEqual(opts["use_highways"], 1.0)
        XCTAssertEqual(opts["use_tolls"], 1.0)
        XCTAssertEqual(opts["use_trails"], 0.0)
        XCTAssertEqual(opts["use_tracks"], 0.0)

        // Fallback policy: MapKit natively supported
        XCTAssertTrue(profile.fallbackPolicy.allowMapKitFallback)
        XCTAssertEqual(profile.fallbackPolicy.mapKitCapability, .native)
    }

    // MARK: - 3. Bicycle & Pedestrian Profiles

    func testBicycleProfile_Defaults() {
        let profile = RoutingProfile.profile(for: .bicycle)

        XCTAssertEqual(profile.transportMode, .bicycle)
        XCTAssertEqual(profile.valhallaCosting, "bicycle")
        XCTAssertEqual(profile.costingOptions.numericOptions["use_roads"], 0.5)
        XCTAssertEqual(profile.costingOptions.numericOptions["use_hills"], 0.2)
    }

    func testPedestrianProfile_Defaults() {
        let profile = RoutingProfile.profile(for: .pedestrian)

        XCTAssertEqual(profile.transportMode, .pedestrian)
        XCTAssertEqual(profile.valhallaCosting, "pedestrian")
        XCTAssertEqual(profile.costingOptions.numericOptions["use_lit"], 0.5)
        XCTAssertEqual(profile.fallbackPolicy.mapKitCapability, .native)
    }

    // MARK: - 4. Transport Mode Parsing

    func testNavigationTransportMode_FromStringConversion() {
        XCTAssertEqual(NavigationTransportMode(costingValue: "motorcycle"), .motorcycle)
        XCTAssertEqual(NavigationTransportMode(costingValue: "Xe máy"), .motorcycle)
        XCTAssertEqual(NavigationTransportMode(costingValue: "xe may"), .motorcycle)
        XCTAssertEqual(NavigationTransportMode(costingValue: "random_unknown"), .motorcycle)

        XCTAssertEqual(NavigationTransportMode(costingValue: "auto"), .auto)
        XCTAssertEqual(NavigationTransportMode(costingValue: "car"), .auto)
        XCTAssertEqual(NavigationTransportMode(costingValue: "automobile"), .auto)
        XCTAssertEqual(NavigationTransportMode(costingValue: "Ô tô"), .auto)

        XCTAssertEqual(NavigationTransportMode(costingValue: "bicycle"), .bicycle)
        XCTAssertEqual(NavigationTransportMode(costingValue: "bike"), .bicycle)
        XCTAssertEqual(NavigationTransportMode(costingValue: "xe đạp"), .bicycle)

        XCTAssertEqual(NavigationTransportMode(costingValue: "pedestrian"), .pedestrian)
        XCTAssertEqual(NavigationTransportMode(costingValue: "walk"), .pedestrian)
        XCTAssertEqual(NavigationTransportMode(costingValue: "đi bộ"), .pedestrian)
    }

    // MARK: - 5. Structured Request JSON Serialization

    func testValhallaRequestBuilder_BuildsValidJSON() throws {
        let origin = CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542)
        let destination = CLLocationCoordinate2D(latitude: 21.0368, longitude: 105.8346)
        let profile = RoutingProfile.profile(for: .motorcycle)

        let jsonString = try ValhallaRequestBuilder.buildRequestJSON(
            origin: origin,
            destination: destination,
            profile: profile,
            alternates: 2
        )

        guard let data = jsonString.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to deserialize generated JSON string")
            return
        }

        // Top-level fields
        XCTAssertEqual(dict["costing"] as? String, "motorcycle")
        XCTAssertEqual(dict["format"] as? String, "json")
        XCTAssertEqual(dict["alternates"] as? Int, 2)

        // Locations
        guard let locs = dict["locations"] as? [[String: Any]], locs.count == 2 else {
            XCTFail("Invalid locations array")
            return
        }
        XCTAssertEqual(locs[0]["lat"] as? Double, origin.latitude)
        XCTAssertEqual(locs[0]["lon"] as? Double, origin.longitude)
        XCTAssertEqual(locs[1]["lat"] as? Double, destination.latitude)
        XCTAssertEqual(locs[1]["lon"] as? Double, destination.longitude)

        // Costing options
        guard let costingOpts = dict["costing_options"] as? [String: Any],
              let motoOpts = costingOpts["motorcycle"] as? [String: Any] else {
            XCTFail("Invalid costing_options dictionary")
            return
        }
        XCTAssertEqual(motoOpts["use_trails"] as? Double, 0.0)
        XCTAssertEqual(motoOpts["use_tracks"] as? Double, 0.0)
        XCTAssertEqual(motoOpts["use_highways"] as? Double, 0.5)
        XCTAssertEqual(motoOpts["use_tolls"] as? Double, 0.5)

        // Directions options
        guard let dirOpts = dict["directions_options"] as? [String: Any] else {
            XCTFail("Missing directions_options")
            return
        }
        XCTAssertEqual(dirOpts["language"] as? String, "vi")
        XCTAssertEqual(dirOpts["units"] as? String, "kilometers")
        XCTAssertEqual(dirOpts["narrative"] as? Bool, true)
    }

    func testValhallaRequestBuilder_ZeroAlternatesOmitsAlternatesKey() throws {
        let origin = CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542)
        let destination = CLLocationCoordinate2D(latitude: 21.0368, longitude: 105.8346)
        let profile = RoutingProfile.profile(for: .auto)

        let jsonString = try ValhallaRequestBuilder.buildRequestJSON(
            origin: origin,
            destination: destination,
            profile: profile,
            alternates: 0
        )

        guard let data = jsonString.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to deserialize generated JSON string")
            return
        }

        XCTAssertNil(dict["alternates"], "alternates key should be omitted when alternates <= 0")
    }

    // MARK: - 6. RoutingRequest Equality

    func testRoutingRequest_Equality() {
        let coord1 = CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8)
        let coord2 = CLLocationCoordinate2D(latitude: 21.1, longitude: 105.9)
        let profileA = RoutingProfile.profile(for: .motorcycle)
        let profileB = RoutingProfile.profile(for: .auto)

        let req1 = RoutingRequest(origin: coord1, destination: coord2, profile: profileA, requestedAlternatives: 2)
        let req2 = RoutingRequest(origin: coord1, destination: coord2, profile: profileA, requestedAlternatives: 2)
        let req3 = RoutingRequest(origin: coord1, destination: coord2, profile: profileB, requestedAlternatives: 2)

        XCTAssertEqual(req1, req2)
        XCTAssertNotEqual(req1, req3)
    }
}
