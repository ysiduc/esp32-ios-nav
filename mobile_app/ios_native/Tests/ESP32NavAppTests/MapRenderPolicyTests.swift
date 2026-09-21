//
//  MapRenderPolicyTests.swift
//  Unit tests for MapLibre rendering policies, in-place shape updates, and preview zoom caching.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

final class MapRenderPolicyTests: XCTestCase {

    private var policy: MapRenderPolicy!

    override func setUp() {
        super.setUp()
        policy = MapRenderPolicy()
    }

    override func tearDown() {
        policy = nil
        super.tearDown()
    }

    func testInitialBuild_WhenSourceDoesNotExist() {
        let action = policy.evaluatePolylineUpdate(coordsCount: 10, sourceExists: false, layerExists: false)
        XCTAssertEqual(action, .initialBuild)
    }

    func testInPlaceShapeUpdate_WhenSourceAndLayerExist() {
        let action = policy.evaluatePolylineUpdate(coordsCount: 10, sourceExists: true, layerExists: true)
        XCTAssertEqual(action, .updateShapeInPlace)
    }

    func testRebuild_WhenLayerMissing() {
        let action = policy.evaluatePolylineUpdate(coordsCount: 10, sourceExists: true, layerExists: false)
        XCTAssertEqual(action, .rebuildForMissingLayer)
    }

    func testClearShape_WhenCoordsLessThan2() {
        let action = policy.evaluatePolylineUpdate(coordsCount: 1, sourceExists: true, layerExists: true)
        XCTAssertEqual(action, .clearShape)
    }

    func test100LocationUpdates_OnlyUpdatesShapeInPlace() {
        // First frame: initial build
        let firstAction = policy.evaluatePolylineUpdate(coordsCount: 50, sourceExists: false, layerExists: false)
        if firstAction == .initialBuild {
            policy.recordLayerRebuild()
        }

        // 100 subsequent GPS updates during active navigation
        for _ in 1...100 {
            let action = policy.evaluatePolylineUpdate(coordsCount: 45, sourceExists: true, layerExists: true)
            if action == .updateShapeInPlace {
                policy.recordShapeUpdate()
            } else if action == .rebuildForMissingLayer || action == .initialBuild {
                policy.recordLayerRebuild()
            }
        }

        XCTAssertEqual(policy.routeShapeUpdates, 100, "100 location updates must perform 100 in-place shape updates")
        XCTAssertEqual(policy.routeLayerRebuilds, 1, "Route layers must only be built once (0 rebuilds during navigation)")
    }

    func testPreviewZoomCaching_PreventsRepeatedZoom() {
        let coordsA = [
            CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542),
            CLLocationCoordinate2D(latitude: 21.0350, longitude: 105.8542)
        ]

        // First presentation of Route A
        XCTAssertTrue(policy.shouldZoomToFit(routeCoordinates: coordsA))
        policy.recordPreviewZoom()

        // 5 subsequent routine SwiftUI body updates with the same Route A
        for _ in 1...5 {
            XCTAssertFalse(policy.shouldZoomToFit(routeCoordinates: coordsA), "Repeated view updates with same route must not re-trigger camera zoom")
        }

        XCTAssertEqual(policy.previewZooms, 1)

        // User chooses Route B (different destination/length)
        let coordsB = [
            CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542),
            CLLocationCoordinate2D(latitude: 21.0400, longitude: 105.8600)
        ]
        XCTAssertTrue(policy.shouldZoomToFit(routeCoordinates: coordsB), "New route selection must trigger zoomToFit")
        policy.recordPreviewZoom()

        XCTAssertEqual(policy.previewZooms, 2)
    }
}
