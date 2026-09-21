//
//  AppLifecycleNavigationTests.swift
//  Unit tests for scene phase lifecycle, background navigation persistence, and power suspension.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

@MainActor
final class AppLifecycleNavigationTests: XCTestCase {

    private var sessionManager: NavigationSessionManager!

    private let dummyRoute = NavRoute(
        coordinates: [
            CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8),
            CLLocationCoordinate2D(latitude: 21.1, longitude: 105.8)
        ],
        steps: [],
        totalDistanceMeters: 1000,
        totalDurationSeconds: 100
    )
    private let dummyDest = NavigationDestination(
        coordinate: CLLocationCoordinate2D(latitude: 21.1, longitude: 105.8),
        name: "Dest"
    )

    override func setUp() {
        super.setUp()
        sessionManager = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
    }

    override func tearDown() {
        sessionManager.stopNavigation()
        sessionManager = nil
        super.tearDown()
    }

    func testLifecycle_ForegroundIdle_To_BackgroundIdle_Suspends() {
        // App active in foreground idle
        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertEqual(sessionManager.trackingProfile, .foregroundPassive)

        // App enters background
        sessionManager.handleScenePhaseChange(isForeground: false)
        XCTAssertEqual(sessionManager.trackingProfile, .suspended, "Background non-navigation must suspend location tracking")
        XCTAssertFalse(sessionManager.currentTrackingConfig.allowsBackgroundLocationUpdates)

        // App returns to foreground
        sessionManager.handleScenePhaseChange(isForeground: true)
        XCTAssertEqual(sessionManager.trackingProfile, .foregroundPassive, "Returning to foreground idle must restore passive tracking")
    }

    func testLifecycle_RoutePreview_To_Background_Suspends() {
        sessionManager.setRoutePreview(route: dummyRoute)
        XCTAssertEqual(sessionManager.state, .routePreview)
        XCTAssertEqual(sessionManager.trackingProfile, .routePreview)

        // Enters background
        sessionManager.handleScenePhaseChange(isForeground: false)
        XCTAssertEqual(sessionManager.trackingProfile, .suspended)

        // Returns to foreground
        sessionManager.handleScenePhaseChange(isForeground: true)
        XCTAssertEqual(sessionManager.trackingProfile, .routePreview)
    }

    func testLifecycle_Navigating_ContinuesInForegroundAndBackground() {
        sessionManager.startNavigation(route: dummyRoute, destination: dummyDest)
        XCTAssertEqual(sessionManager.state, .navigating)
        XCTAssertEqual(sessionManager.trackingProfile, .activeNavigation)
        XCTAssertTrue(sessionManager.currentTrackingConfig.allowsBackgroundLocationUpdates)

        // App enters background while actively navigating
        sessionManager.handleScenePhaseChange(isForeground: false)
        XCTAssertEqual(sessionManager.trackingProfile, .activeNavigation, "Active navigation must persist high-accuracy tracking in background")
        XCTAssertTrue(sessionManager.currentTrackingConfig.allowsBackgroundLocationUpdates)

        // App returns to foreground
        sessionManager.handleScenePhaseChange(isForeground: true)
        XCTAssertEqual(sessionManager.trackingProfile, .activeNavigation)
    }

    func testLifecycle_StopNavigationWhileInBackground_ReleasesResources() {
        sessionManager.startNavigation(route: dummyRoute, destination: dummyDest)
        sessionManager.handleScenePhaseChange(isForeground: false)
        XCTAssertEqual(sessionManager.trackingProfile, .activeNavigation)

        // Navigation stopped while app is in background
        sessionManager.stopNavigation()

        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertEqual(sessionManager.trackingProfile, .suspended, "Stopping navigation while in background must immediately suspend tracking")
        XCTAssertFalse(sessionManager.currentTrackingConfig.allowsBackgroundLocationUpdates)
    }
}
