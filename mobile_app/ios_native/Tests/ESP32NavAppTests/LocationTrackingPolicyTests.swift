//
//  LocationTrackingPolicyTests.swift
//  Unit tests for location tracking profiles, activity mapping, and policy resolution.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

@MainActor
final class LocationTrackingPolicyTests: XCTestCase {

    func testProfileConfiguration_Suspended() {
        let config = LocationTrackingPolicy.configuration(for: .suspended, transportMode: .motorcycle)
        XCTAssertEqual(config.desiredAccuracy, kCLLocationAccuracyThreeKilometers)
        XCTAssertEqual(config.distanceFilter, 1000.0)
        XCTAssertFalse(config.headingEnabled)
        XCTAssertTrue(config.pausesLocationUpdatesAutomatically)
        XCTAssertFalse(config.allowsBackgroundLocationUpdates)
        XCTAssertFalse(config.showsBackgroundLocationIndicator)
    }

    func testProfileConfiguration_ForegroundPassive() {
        let config = LocationTrackingPolicy.configuration(for: .foregroundPassive, transportMode: .motorcycle)
        XCTAssertEqual(config.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(config.distanceFilter, 10.0)
        XCTAssertFalse(config.headingEnabled)
        XCTAssertTrue(config.pausesLocationUpdatesAutomatically)
        XCTAssertFalse(config.allowsBackgroundLocationUpdates)
        XCTAssertFalse(config.showsBackgroundLocationIndicator)
    }

    func testProfileConfiguration_RoutePreview() {
        let config = LocationTrackingPolicy.configuration(for: .routePreview, transportMode: .motorcycle)
        XCTAssertEqual(config.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(config.distanceFilter, 10.0)
        XCTAssertFalse(config.headingEnabled)
        XCTAssertTrue(config.pausesLocationUpdatesAutomatically)
        XCTAssertFalse(config.allowsBackgroundLocationUpdates)
        XCTAssertFalse(config.showsBackgroundLocationIndicator)
    }

    func testProfileConfiguration_ActiveNavigation() {
        let config = LocationTrackingPolicy.configuration(for: .activeNavigation, transportMode: .motorcycle)
        XCTAssertEqual(config.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(config.distanceFilter, kCLDistanceFilterNone)
        XCTAssertTrue(config.headingEnabled)
        XCTAssertFalse(config.pausesLocationUpdatesAutomatically)
        XCTAssertTrue(config.allowsBackgroundLocationUpdates)
        XCTAssertTrue(config.showsBackgroundLocationIndicator)
    }

    func testActivityTypeMapping() {
        XCTAssertEqual(LocationActivityTypeMapper.activityType(for: .motorcycle), .automotiveNavigation)
        XCTAssertEqual(LocationActivityTypeMapper.activityType(for: .auto), .automotiveNavigation)
        XCTAssertEqual(LocationActivityTypeMapper.activityType(for: .pedestrian), .fitness)
        XCTAssertEqual(LocationActivityTypeMapper.activityType(for: .bicycle), .otherNavigation)
    }

    func testProfileResolution_Foreground() {
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .idle, isForeground: true), .foregroundPassive)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .searching, isForeground: true), .foregroundPassive)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .routePreview, isForeground: true), .routePreview)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .navigating, isForeground: true), .activeNavigation)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .arrived, isForeground: true), .foregroundPassive)
    }

    func testProfileResolution_Background() {
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .idle, isForeground: false), .suspended)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .searching, isForeground: false), .suspended)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .routePreview, isForeground: false), .suspended)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .arrived, isForeground: false), .suspended)
        XCTAssertEqual(LocationTrackingPolicy.resolveProfile(state: .navigating, isForeground: false), .activeNavigation)
    }

    func testTransportModeChange_UpdatesActivityTypeWithoutRestartingSession() {
        let session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        let route = NavRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8),
                CLLocationCoordinate2D(latitude: 21.1, longitude: 105.8)
            ],
            steps: [],
            totalDistanceMeters: 1000,
            totalDurationSeconds: 100
        )
        session.startNavigation(route: route, destination: NavigationDestination(coordinate: route.coordinates.last!, name: "Dest"))

        XCTAssertEqual(session.trackingProfile, .activeNavigation)
        XCTAssertEqual(session.currentTrackingConfig.activityType, .automotiveNavigation)

        // Change mode to pedestrian
        session.updateTransportMode(.pedestrian)

        XCTAssertEqual(session.state, .navigating)
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, 1000)
        XCTAssertEqual(session.trackingProfile, .activeNavigation)
        XCTAssertEqual(session.currentTrackingConfig.activityType, .fitness, "Activity type must update to fitness for pedestrian")
    }
}
