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

    // MARK: - Requirement 23: Mixed-Failure Test

    func testMotorcycleMixedFailure_DoesNotInjectMapKitCarRoutes() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)

        // Mock:
        // balanced -> Valhalla route A
        // main-road -> failure
        // local -> Valhalla route B
        // low-toll -> failure
        mockRouting.onCalculateRoutes = { request in
            if request.profile.id == "motorcycle_balanced" {
                let coords = [origin, CLLocationCoordinate2D(latitude: 21.015, longitude: 105.800), dest]
                let r = NavRoute(coordinates: coords, steps: [], totalDistanceMeters: 3000, totalDurationSeconds: 400)
                let c = RouteCandidate(id: "valhalla_balanced_A", route: r, provider: .valhalla, requestedMode: .motorcycle, profileID: request.profile.id, isPrimary: true, isDegradedFallback: false)
                return RouteSet(candidates: [c])
            } else if request.profile.id == "motorcycle_local" {
                let coords = [origin, CLLocationCoordinate2D(latitude: 21.015, longitude: 105.815), dest]
                let r = NavRoute(coordinates: coords, steps: [], totalDistanceMeters: 3200, totalDurationSeconds: 450)
                let c = RouteCandidate(id: "valhalla_local_B", route: r, provider: .valhalla, requestedMode: .motorcycle, profileID: request.profile.id, isPrimary: false, isDegradedFallback: false)
                return RouteSet(candidates: [c])
            } else {
                throw ValhallaRoutingError.noRouteFound("Strategy unavailable")
            }
        }

        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 2)

        let set = try await planner.calculateRoutes(request: req)

        // Must contain only A and B
        XCTAssertEqual(set.candidates.count, 2)
        for candidate in set.candidates {
            XCTAssertEqual(candidate.provider, .valhalla, "Mixed failure must not allow MapKit car routes to enter motorcycle pool")
            XCTAssertFalse(candidate.isDegradedFallback, "Usable Valhalla candidates must not be degraded fallback")
        }
        let candidateIDs = set.candidates.map { $0.id }
        XCTAssertTrue(candidateIDs.contains("valhalla_balanced_A"))
        XCTAssertTrue(candidateIDs.contains("valhalla_local_B"))
    }

    // MARK: - Requirement 24: All-Valhalla-Fail Emergency Fallback Test

    func testAllValhallaStrategiesFail_ProducesOneDegradedMapKitFallback() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)

        // Mock: All 4 Valhalla strategies fail; fallback succeeds with MapKit degraded route
        mockRouting.onCalculateRoutes = { request in
            if request.requestedAlternatives == 0 {
                // Emergency single-route fallback
                let r = NavRoute(coordinates: [origin, dest], steps: [], totalDistanceMeters: 3500, totalDurationSeconds: 500)
                let c = RouteCandidate(
                    id: "emergency_mapkit_fallback",
                    route: r,
                    provider: .mapKit,
                    requestedMode: .motorcycle,
                    profileID: request.profile.id,
                    isPrimary: true,
                    isDegradedFallback: true
                )
                return RouteSet(candidates: [c])
            } else {
                throw ValhallaRoutingError.noRouteFound("Valhalla server down")
            }
        }

        let profile = RoutingProfile.profile(for: .motorcycle)
        let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 2)

        let set = try await planner.calculateRoutes(request: req)

        // Must produce exactly 1 degraded MapKit candidate
        XCTAssertEqual(set.candidates.count, 1)
        XCTAssertEqual(set.candidates[0].id, "emergency_mapkit_fallback")
        XCTAssertEqual(set.candidates[0].provider, .mapKit)
        XCTAssertTrue(set.candidates[0].isDegradedFallback)

        // Verify that emergency fallback was queried with requestedAlternatives = 0
        let fallbackCalls = mockRouting.calculateRoutesCalls.filter { $0.requestedAlternatives == 0 }
        XCTAssertEqual(fallbackCalls.count, 1, "Emergency fallback must request exactly 0 alternatives")
    }

    // MARK: - Requirement 31: Completion-Order Independence Test

    func testCompletionOrderIndependence_ProducesDeterministicCandidateOrder() async throws {
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.800)

        // Define distinct geometries for the 4 strategies
        let strategyData: [String: (offset: Double, duration: Double, dist: Double)] = [
            "motorcycle_balanced": (0.000, 400, 3000),
            "motorcycle_main_roads": (0.010, 420, 3200),
            "motorcycle_local": (-0.010, 440, 3100),
            "motorcycle_low_toll": (0.020, 460, 3300)
        ]

        func runPlanner(withDelays delays: [String: UInt64]) async throws -> [String] {
            let mock = MockUnderlyingRoutingService()
            mock.onCalculateRoutes = { request in
                let delay = delays[request.profile.id] ?? 0
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                guard let data = strategyData[request.profile.id] else {
                    throw ValhallaRoutingError.noRouteFound("Unknown profile")
                }
                let coords = [
                    origin,
                    CLLocationCoordinate2D(latitude: 21.015, longitude: 105.800 + data.offset),
                    dest
                ]
                let r = NavRoute(coordinates: coords, steps: [], totalDistanceMeters: data.dist, totalDurationSeconds: data.duration)
                let c = RouteCandidate(
                    id: "\(request.profile.id)_c0",
                    route: r,
                    provider: .valhalla,
                    requestedMode: .motorcycle,
                    profileID: request.profile.id,
                    isPrimary: request.profile.id == "motorcycle_balanced"
                )
                return RouteSet(candidates: [c])
            }

            let p = MultiStrategyRoutePlanner(underlyingRouting: mock)
            let profile = RoutingProfile.profile(for: .motorcycle)
            let req = RoutingRequest(origin: origin, destination: dest, profile: profile, requestedAlternatives: 3)
            let result = try await p.calculateRoutes(request: req)
            return result.candidates.map { $0.id }
        }

        // Run A: local finishes first
        let delaysA: [String: UInt64] = [
            "motorcycle_local": 1_000_000,        // 1ms
            "motorcycle_main_roads": 20_000_000,  // 20ms
            "motorcycle_low_toll": 40_000_000,    // 40ms
            "motorcycle_balanced": 60_000_000     // 60ms
        ]
        let orderA = try await runPlanner(withDelays: delaysA)

        // Run B: main-road finishes first
        let delaysB: [String: UInt64] = [
            "motorcycle_main_roads": 1_000_000,   // 1ms
            "motorcycle_local": 20_000_000,       // 20ms
            "motorcycle_balanced": 40_000_000,    // 40ms
            "motorcycle_low_toll": 60_000_000     // 60ms
        ]
        let orderB = try await runPlanner(withDelays: delaysB)

        // Run C: balanced finishes last
        let delaysC: [String: UInt64] = [
            "motorcycle_low_toll": 1_000_000,     // 1ms
            "motorcycle_main_roads": 20_000_000,  // 20ms
            "motorcycle_local": 40_000_000,       // 40ms
            "motorcycle_balanced": 60_000_000     // 60ms
        ]
        let orderC = try await runPlanner(withDelays: delaysC)

        // Candidate ordering must be completely deterministic regardless of completion order!
        XCTAssertEqual(orderA, orderB, "Order in Run A and Run B must be identical")
        XCTAssertEqual(orderA, orderC, "Order in Run A and Run C must be identical")
        XCTAssertEqual(orderA.first, "motorcycle_balanced_c0", "Balanced candidate must be primary first")
    }
}

