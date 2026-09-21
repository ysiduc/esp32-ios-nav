//
//  MultiStrategyRoutePlannerTests.swift
//  Unit tests for MultiStrategyRoutePlanner concurrent aggregation, partial failure resilience,
//  corridor deduplication, and fast single-route reroute bypass.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

// MARK: - Mock Underlying Routing Service

@MainActor
final class MockUnderlyingRoutingService: RoutingServiceProtocol {
    var onCalculateRoutes: ((RoutingRequest) async throws -> RouteSet)?
    var calculateRoutesCalls: [RoutingRequest] = []
    var calculateRouteCalls: [(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D, costing: String)] = []

    func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        calculateRoutesCalls.append(request)
        if let handler = onCalculateRoutes {
            return try await handler(request)
        }

        // Default: return route with offset coordinate based on profile id
        let offset = Double(request.profile.id.hashValue % 10) * 0.005
        let coords = [
            request.origin,
            CLLocationCoordinate2D(latitude: (request.origin.latitude + request.destination.latitude) / 2.0,
                                   longitude: ((request.origin.longitude + request.destination.longitude) / 2.0) + offset),
            request.destination
        ]
        let route = NavRoute(coordinates: coords, steps: [], totalDistanceMeters: 5000, totalDurationSeconds: 600)
        let candidate = RouteCandidate(
            id: "\(request.profile.id)_c0",
            route: route,
            provider: .valhalla,
            requestedMode: request.profile.transportMode,
            profileID: request.profile.id,
            isPrimary: true
        )
        return RouteSet(candidates: [candidate])
    }

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        calculateRouteCalls.append((origin, destination, costing))
        return NavRoute(
            coordinates: [origin, destination],
            steps: [],
            totalDistanceMeters: 5000,
            totalDurationSeconds: 600
        )
    }
}

// MARK: - MultiStrategyRoutePlannerTests

@MainActor
final class MultiStrategyRoutePlannerTests: XCTestCase {

    var mockRouting: MockUnderlyingRoutingService!
    var planner: MultiStrategyRoutePlanner!

    override func setUp() async throws {
        try await super.setUp()
        mockRouting = MockUnderlyingRoutingService()
        planner = MultiStrategyRoutePlanner(underlyingRouting: mockRouting)
    }

    func testConcurrentExecution_AggregatesDistinctStrategies() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)
        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 2)

        let set = try await planner.calculateRoutes(request: req)

        // Multiple strategies executed concurrently
        XCTAssertGreaterThan(mockRouting.calculateRoutesCalls.count, 1)
        XCTAssertGreaterThanOrEqual(set.candidates.count, 1)
        XCTAssertEqual(set.candidates.first?.isPrimary, true)
    }

    func testConvergentGeometry_ReturnsSingleCandidateWithoutDuplicates() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)
        let fixedRoute = NavRoute(coordinates: [origin, dest], steps: [], totalDistanceMeters: 3000, totalDurationSeconds: 400)

        // All strategies return identical geometry
        mockRouting.onCalculateRoutes = { request in
            let c = RouteCandidate(id: "\(request.profile.id)", route: fixedRoute, provider: .valhalla, requestedMode: .motorcycle, profileID: request.profile.id, isPrimary: true)
            return RouteSet(candidates: [c])
        }

        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 2)

        let set = try await planner.calculateRoutes(request: req)

        // Exactly 1 route returned because all were duplicates
        XCTAssertEqual(set.candidates.count, 1)
        XCTAssertEqual(set.candidates.first?.isPrimary, true)
    }

    func testPartialStrategyFailure_ReturnsRemainingSuccessfulCandidates() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)

        // Main roads fails, balanced succeeds
        mockRouting.onCalculateRoutes = { request in
            if request.profile.id == "motorcycle_main_roads" {
                throw ValhallaRoutingError.noRouteFound("Strategy error")
            }
            let coords = [
                origin,
                CLLocationCoordinate2D(latitude: 21.015, longitude: 105.800 + (request.profile.id == "motorcycle_local" ? 0.01 : 0.0)),
                dest
            ]
            let r = NavRoute(coordinates: coords, steps: [], totalDistanceMeters: 3000, totalDurationSeconds: 400)
            let c = RouteCandidate(id: request.profile.id, route: r, provider: .valhalla, requestedMode: .motorcycle, profileID: request.profile.id, isPrimary: request.profile.id == "motorcycle_balanced")
            return RouteSet(candidates: [c])
        }

        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 2)

        let set = try await planner.calculateRoutes(request: req)

        XCTAssertFalse(set.candidates.isEmpty)
        XCTAssertEqual(set.candidates.first?.isPrimary, true)
    }

    func testAllStrategiesFail_ThrowsError() async {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)

        mockRouting.onCalculateRoutes = { _ in
            throw ValhallaRoutingError.noRouteFound("Engine failure")
        }

        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 2)

        do {
            _ = try await planner.calculateRoutes(request: req)
            XCTFail("Expected error when all strategies fail")
        } catch {
            XCTAssertTrue(error is ValhallaRoutingError)
        }
    }

    func testReroute_SingleRouteBypassesMultiStrategy() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)

        // Reroutes call calculateRoute(from:to:costing:)
        let route = try await planner.calculateRoute(from: origin, to: dest, costing: "motorcycle")

        XCTAssertEqual(route.coordinates.count, 2)
        XCTAssertEqual(mockRouting.calculateRouteCalls.count, 1)
        XCTAssertEqual(mockRouting.calculateRoutesCalls.count, 0)
    }

    func testRequestedAlternativesZero_BypassesMultiStrategy() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)
        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 0)

        _ = try await planner.calculateRoutes(request: req)

        // Exactly 1 underlying call made, no multi-strategy spawning
        XCTAssertEqual(mockRouting.calculateRoutesCalls.count, 1)
    }
}
