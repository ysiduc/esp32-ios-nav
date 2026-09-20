//
//  ValhallaRouteSetParserTests.swift
//  Unit tests for Valhalla JSON response parsing (primary + alternatives) and candidate deduplication.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

final class ValhallaRouteSetParserTests: XCTestCase {

    // MARK: - 1. Single Primary Route Parsing

    func testParseSinglePrimaryRoute() throws {
        let json = """
        {
            "trip": {
                "status": 0,
                "status_message": "Found route between points",
                "units": "kilometers",
                "language": "vi",
                "summary": {
                    "length": 2.5,
                    "time": 300
                },
                "legs": [
                    {
                        "shape": "_p~iF~ps|U_ulLnnqC_mqNvxq",
                        "maneuvers": [
                            {
                                "type": 1,
                                "instruction": "Đi thẳng trên Đường Giải Phóng",
                                "length": 1.0,
                                "time": 120,
                                "street_names": ["Đường Giải Phóng"],
                                "begin_shape_index": 0,
                                "end_shape_index": 5
                            },
                            {
                                "type": 15,
                                "instruction": "Rẽ phải vào Phố Lê Duẩn",
                                "length": 1.5,
                                "time": 180,
                                "street_names": ["Phố Lê Duẩn"],
                                "begin_shape_index": 5,
                                "end_shape_index": 12
                            }
                        ]
                    }
                ]
            }
        }
        """

        let result = try ValhallaEngine.shared().parseValhallaJSONResult(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.primaryRoute.totalDistanceMeters, 2500, accuracy: 1e-3)
        XCTAssertEqual(result.primaryRoute.totalDurationSeconds, 300, accuracy: 1e-3)
        XCTAssertEqual(result.primaryRoute.steps.count, 2)
        XCTAssertEqual(result.primaryRoute.steps[0].instruction, "Đi thẳng trên Đường Giải Phóng")
        XCTAssertEqual(result.primaryRoute.steps[0].streetName, "Đường Giải Phóng")
        XCTAssertEqual(result.primaryRoute.steps[0].beginShapeIndex, 0)
        XCTAssertEqual(result.primaryRoute.steps[0].endShapeIndex, 5)

        XCTAssertEqual(result.alternativeRoutes.count, 0)
        XCTAssertEqual(result.allRoutes.count, 1)
    }

    // MARK: - 2. Primary + Two Alternatives Parsing

    func testParsePrimaryPlusTwoAlternatives() throws {
        let json = """
        {
            "trip": {
                "summary": { "length": 3.0, "time": 360 },
                "legs": [
                    {
                        "shape": "shape_primary_route",
                        "maneuvers": [
                            { "type": 1, "instruction": "Primary Step 1", "length": 3.0, "time": 360, "begin_shape_index": 0, "end_shape_index": 10 }
                        ]
                    }
                ]
            },
            "alternates": [
                {
                    "trip": {
                        "summary": { "length": 3.5, "time": 420 },
                        "legs": [
                            {
                                "shape": "shape_alt1_route",
                                "maneuvers": [
                                    { "type": 2, "instruction": "Alt1 Step 1", "length": 3.5, "time": 420, "begin_shape_index": 0, "end_shape_index": 14 }
                                ]
                            }
                        ]
                    }
                },
                {
                    "trip": {
                        "summary": { "length": 4.0, "time": 480 },
                        "legs": [
                            {
                                "shape": "shape_alt2_route",
                                "maneuvers": [
                                    { "type": 3, "instruction": "Alt2 Step 1", "length": 4.0, "time": 480, "begin_shape_index": 0, "end_shape_index": 18 }
                                ]
                            }
                        ]
                    }
                }
            ]
        }
        """

        let result = try ValhallaEngine.shared().parseValhallaJSONResult(json)
        XCTAssertNotNil(result)

        // Primary route
        XCTAssertEqual(result.primaryRoute.totalDistanceMeters, 3000, accuracy: 1e-3)
        XCTAssertEqual(result.primaryRoute.totalDurationSeconds, 360, accuracy: 1e-3)
        XCTAssertEqual(result.primaryRoute.encodedPolyline6, "shape_primary_route")
        XCTAssertEqual(result.primaryRoute.steps[0].instruction, "Primary Step 1")

        // Two alternatives
        XCTAssertEqual(result.alternativeRoutes.count, 2)
        XCTAssertEqual(result.allRoutes.count, 3)

        // Alternative 1
        let alt1 = result.alternativeRoutes[0]
        XCTAssertEqual(alt1.totalDistanceMeters, 3500, accuracy: 1e-3)
        XCTAssertEqual(alt1.totalDurationSeconds, 420, accuracy: 1e-3)
        XCTAssertEqual(alt1.encodedPolyline6, "shape_alt1_route")
        XCTAssertEqual(alt1.steps[0].instruction, "Alt1 Step 1")
        XCTAssertEqual(alt1.steps[0].endShapeIndex, 14)

        // Alternative 2
        let alt2 = result.alternativeRoutes[1]
        XCTAssertEqual(alt2.totalDistanceMeters, 4000, accuracy: 1e-3)
        XCTAssertEqual(alt2.totalDurationSeconds, 480, accuracy: 1e-3)
        XCTAssertEqual(alt2.encodedPolyline6, "shape_alt2_route")
        XCTAssertEqual(alt2.steps[0].instruction, "Alt2 Step 1")
        XCTAssertEqual(alt2.steps[0].endShapeIndex, 18)
    }

    // MARK: - 3. Shape Index Isolation Across Routes

    func testAlternateStepsHaveIndependentShapeIndices() throws {
        let json = """
        {
            "trip": {
                "summary": { "length": 1.0, "time": 100 },
                "legs": [{
                    "shape": "AAAA",
                    "maneuvers": [
                        { "type": 1, "instruction": "P1", "length": 0.5, "time": 50, "begin_shape_index": 0, "end_shape_index": 2 },
                        { "type": 1, "instruction": "P2", "length": 0.5, "time": 50, "begin_shape_index": 2, "end_shape_index": 4 }
                    ]
                }]
            },
            "alternates": [
                {
                    "summary": { "length": 2.0, "time": 200 },
                    "legs": [{
                        "shape": "BBBBBB",
                        "maneuvers": [
                            { "type": 2, "instruction": "A1", "length": 2.0, "time": 200, "begin_shape_index": 0, "end_shape_index": 6 }
                        ]
                    }]
                }
            ]
        }
        """

        let result = try ValhallaEngine.shared().parseValhallaJSONResult(json)
        XCTAssertEqual(result.primaryRoute.steps.count, 2)
        XCTAssertEqual(result.primaryRoute.steps[1].endShapeIndex, 4)

        XCTAssertEqual(result.alternativeRoutes.count, 1)
        XCTAssertEqual(result.alternativeRoutes[0].steps.count, 1)
        XCTAssertEqual(result.alternativeRoutes[0].steps[0].beginShapeIndex, 0)
        XCTAssertEqual(result.alternativeRoutes[0].steps[0].endShapeIndex, 6)
    }

    // MARK: - 4. Error Classification

    func testNoRouteFound_ProducesError() {
        let json = """
        {
            "error": "No route found between locations",
            "status_code": 404
        }
        """

        XCTAssertThrowsError(try ValhallaEngine.shared().parseValhallaJSONResult(json)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, ValhallaEngineErrorDomain)
            XCTAssertEqual(nsError.code, ValhallaEngineError.noRouteFound.rawValue)
        }
    }

    // MARK: - 5. Route Set Deduplication

    func testRouteSetDeduplication_RemovesExactDuplicates() {
        let routeA = NavRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8),
                CLLocationCoordinate2D(latitude: 21.1, longitude: 105.9)
            ],
            steps: [],
            totalDistanceMeters: 1000,
            totalDurationSeconds: 120
        )
        let routeADup = NavRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 21.000001, longitude: 105.800001),
                CLLocationCoordinate2D(latitude: 21.100001, longitude: 105.900001)
            ],
            steps: [],
            totalDistanceMeters: 1000,
            totalDurationSeconds: 120
        )
        let routeB = NavRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8),
                CLLocationCoordinate2D(latitude: 21.05, longitude: 105.85),
                CLLocationCoordinate2D(latitude: 21.1, longitude: 105.9)
            ],
            steps: [],
            totalDistanceMeters: 1400,
            totalDurationSeconds: 180
        )

        let candidate0 = RouteCandidate(id: "c0", route: routeA, provider: .valhalla, requestedMode: .motorcycle, profileID: "p", isPrimary: true)
        let candidate1 = RouteCandidate(id: "c1", route: routeADup, provider: .valhalla, requestedMode: .motorcycle, profileID: "p", isPrimary: false)
        let candidate2 = RouteCandidate(id: "c2", route: routeB, provider: .valhalla, requestedMode: .motorcycle, profileID: "p", isPrimary: false)

        let deduped = RouteSet.deduplicate(candidates: [candidate0, candidate1, candidate2])

        // Should eliminate duplicate c1 and keep c0 and c2
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped[0].id, "c0")
        XCTAssertEqual(deduped[0].label, "Đề xuất")
        XCTAssertEqual(deduped[0].relativeDurationSeconds, 0)
        XCTAssertEqual(deduped[0].relativeDistanceMeters, 0)

        XCTAssertEqual(deduped[1].id, "c2")
        XCTAssertEqual(deduped[1].label, "Tuyến 2")
        XCTAssertEqual(deduped[1].relativeDurationSeconds, 60, accuracy: 1e-3)
        XCTAssertEqual(deduped[1].relativeDistanceMeters, 400, accuracy: 1e-3)
    }
}
