//
//  RouteSimilarityTests.swift
//  Unit tests for RouteSimilarity: geometric overlap, corridor matching, endpoint masking, and detour filtering.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

final class RouteSimilarityTests: XCTestCase {

    // MARK: - Helpers

    private func makeRoute(coords: [CLLocationCoordinate2D], duration: Double = 600) -> NavRoute {
        var totalDist: Double = 0
        for i in 0..<(coords.count - 1) {
            totalDist += RouteGeometry.distanceBetween(coords[i], coords[i + 1])
        }
        return NavRoute(
            coordinates: coords,
            steps: [],
            totalDistanceMeters: totalDist,
            totalDurationSeconds: duration
        )
    }

    // MARK: - Overlap Tests

    func testOverlap_IdenticalRoutes_ReturnsHighOverlap() {
        let coords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.010, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.020, longitude: 105.800)
        ]
        let rA = makeRoute(coords: coords)
        let rB = makeRoute(coords: coords)

        let sim = RouteSimilarity.overlap(routeA: rA, routeB: rB)
        XCTAssertGreaterThanOrEqual(sim, 0.95)
    }

    func testOverlap_SameGeometryDifferentSampling_ReturnsHighOverlap() {
        // Route A: 3 sparse points along a ~2.2km straight line
        let coordsA = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.010, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.020, longitude: 105.800)
        ]

        // Route B: 11 dense points along the exact same line
        var coordsB: [CLLocationCoordinate2D] = []
        for i in 0...10 {
            let lat = 21.000 + (Double(i) * 0.002)
            coordsB.append(CLLocationCoordinate2D(latitude: lat, longitude: 105.800))
        }

        let rA = makeRoute(coords: coordsA)
        let rB = makeRoute(coords: coordsB)

        let sim = RouteSimilarity.overlap(routeA: rA, routeB: rB)
        // With 30m corridor, all points overlap
        XCTAssertGreaterThanOrEqual(sim, 0.90)
    }

    func testOverlap_ParallelStreetsSeparatedBy100m_ReturnsLowOverlap() {
        // Route A along lon 105.800
        let coordsA = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.010, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.020, longitude: 105.800)
        ]

        // Route B along lon 105.801 (~104m east in Hanoi)
        let coordsB = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.801),
            CLLocationCoordinate2D(latitude: 21.010, longitude: 105.801),
            CLLocationCoordinate2D(latitude: 21.020, longitude: 105.801)
        ]

        let rA = makeRoute(coords: coordsA)
        let rB = makeRoute(coords: coordsB)

        let sim = RouteSimilarity.overlap(routeA: rA, routeB: rB)
        // 100m separation is well beyond 30m corridor
        XCTAssertLessThan(sim, 0.20)
    }

    func testOverlap_SharedEndpointsMasked_EvaluatesBodyDiversity() {
        // Both share origin (21.000, 105.800) and destination (21.040, 105.800)
        // Middle body diverges by 500m
        let origin = CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800)
        let dest   = CLLocationCoordinate2D(latitude: 21.040, longitude: 105.800)

        let coordsA = [
            origin,
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.020, longitude: 105.800), // straight
            CLLocationCoordinate2D(latitude: 21.038, longitude: 105.800),
            dest
        ]

        let coordsB = [
            origin,
            CLLocationCoordinate2D(latitude: 21.002, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.020, longitude: 105.805), // wide detour ~520m east
            CLLocationCoordinate2D(latitude: 21.038, longitude: 105.800),
            dest
        ]

        let rA = makeRoute(coords: coordsA)
        let rB = makeRoute(coords: coordsB)

        let sim = RouteSimilarity.overlap(routeA: rA, routeB: rB)
        // Because middle 4km is completely divergent, overlap is low
        XCTAssertLessThan(sim, 0.50)
    }

    // MARK: - Detour Quality Filtering

    func testDetourQuality_FiltersExcessiveDuration() {
        let normal = makeRoute(coords: [
            CLLocationCoordinate2D(latitude: 21.00, longitude: 105.80),
            CLLocationCoordinate2D(latitude: 21.01, longitude: 105.80)
        ], duration: 500)

        let excessive = makeRoute(coords: [
            CLLocationCoordinate2D(latitude: 21.00, longitude: 105.80),
            CLLocationCoordinate2D(latitude: 21.01, longitude: 105.80)
        ], duration: 800) // 800 > 500 * 1.40 = 700

        XCTAssertTrue(RouteSimilarity.isAcceptableCandidate(
            candidate: normal,
            fastestDurationSeconds: 500,
            shortestDistanceMeters: 1000
        ))

        XCTAssertFalse(RouteSimilarity.isAcceptableCandidate(
            candidate: excessive,
            fastestDurationSeconds: 500,
            shortestDistanceMeters: 1000
        ))
    }

    // MARK: - RouteSet Deduplication Integration

    func testRouteSetDeduplication_RemovesDifferentSamplingDuplicate() {
        let r1 = makeRoute(coords: [
            CLLocationCoordinate2D(latitude: 21.00, longitude: 105.80),
            CLLocationCoordinate2D(latitude: 21.02, longitude: 105.80)
        ])

        // Resampled version of r1 with intermediate point
        let r2 = makeRoute(coords: [
            CLLocationCoordinate2D(latitude: 21.00, longitude: 105.80),
            CLLocationCoordinate2D(latitude: 21.01, longitude: 105.80),
            CLLocationCoordinate2D(latitude: 21.02, longitude: 105.80)
        ])

        // Truly distinct route 200m away
        let r3 = makeRoute(coords: [
            CLLocationCoordinate2D(latitude: 21.00, longitude: 105.802),
            CLLocationCoordinate2D(latitude: 21.02, longitude: 105.802)
        ])

        let c1 = RouteCandidate(id: "c1", route: r1, provider: .valhalla, requestedMode: .motorcycle, profileID: "p1", isPrimary: true, label: "Đề xuất")
        let c2 = RouteCandidate(id: "c2", route: r2, provider: .valhalla, requestedMode: .motorcycle, profileID: "p2", isPrimary: false, label: "Tuyến 2")
        let c3 = RouteCandidate(id: "c3", route: r3, provider: .valhalla, requestedMode: .motorcycle, profileID: "p3", isPrimary: false, label: "Đường chính")

        let deduped = RouteSet.deduplicate(candidates: [c1, c2, c3])

        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped[0].id, "c1")
        XCTAssertEqual(deduped[1].id, "c3")
        XCTAssertEqual(deduped[1].label, "Đường chính") // Custom label preserved
    }
}
