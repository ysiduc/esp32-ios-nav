//
//  NavigationSessionManagerP51Tests.swift
//  P5.1 regression tests: navigation guard invariants, threshold correctness,
//  arrival profile downgrade, route generation lifecycle, and reroute commit atomicity.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

// MARK: - Helpers

private func makeRoute(
    from: CLLocationCoordinate2D,
    to: CLLocationCoordinate2D,
    distance: Double = 500,
    name: String = "Test Route"
) -> NavRoute {
    NavRoute(
        coordinates: [from, to],
        steps: [
            NavStep(
                coordinate: to,
                distanceMeters: distance,
                durationSeconds: 60,
                streetName: name,
                maneuverType: .straight,
                instruction: "Proceed"
            )
        ],
        totalDistanceMeters: distance,
        totalDurationSeconds: 60
    )
}

private func makeLocation(
    lat: Double, lon: Double,
    accuracy: Double = 5.0,
    speed: Double = 0.0,
    ts: Date = Date()
) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        altitude: 10,
        horizontalAccuracy: accuracy,
        verticalAccuracy: 5,
        course: 0,
        speed: speed,
        timestamp: ts
    )
}

// MARK: - Test Suite

@MainActor
final class NavigationSessionManagerP51Tests: XCTestCase {

    var session: NavigationSessionManager!
    let destCoord  = CLLocationCoordinate2D(latitude: 21.040, longitude: 105.854)
    let startCoord = CLLocationCoordinate2D(latitude: 21.030, longitude: 105.854)
    var route: NavRoute!
    var dest: NavigationDestination!

    override func setUp() async throws {
        session = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        route   = makeRoute(from: startCoord, to: destCoord)
        dest    = NavigationDestination(coordinate: destCoord, name: "Dest")
    }

    override func tearDown() async throws {
        session = nil
    }

    // ─────────────────────────────────────────────
    // Fix 1: setRoutePreview navigation guard
    // ─────────────────────────────────────────────

    func testSetRoutePreview_WhileNavigating_IsRejected() {
        // Arrange: put session into navigating state
        session.startNavigation(route: route, destination: dest)
        XCTAssertEqual(session.state, .navigating)

        let previewRoute = makeRoute(
            from: CLLocationCoordinate2D(latitude: 21.035, longitude: 105.854),
            to:   CLLocationCoordinate2D(latitude: 21.045, longitude: 105.854),
            name: "Preview Route"
        )
        let genBefore = session.activeRouteGeneration
        let routeBefore = session.activeRoute

        // Act: attempt to set a preview while navigating
        session.setRoutePreview(previewRoute)
        session.setRoutePreview(route: previewRoute) // labelled overload

        // Assert: state and route are unchanged
        XCTAssertEqual(session.state, .navigating, "setRoutePreview must not change state while navigating")
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, routeBefore?.totalDistanceMeters,
                       "Active route must not change while navigating")
        XCTAssertEqual(session.activeRouteGeneration, genBefore,
                       "Route generation must not be bumped by a rejected setRoutePreview")
    }

    func testSetRoutePreview_WhileIdle_Succeeds() {
        XCTAssertEqual(session.state, .idle)
        session.setRoutePreview(route)
        XCTAssertEqual(session.state, .routePreview)
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, route.totalDistanceMeters)
    }

    // ─────────────────────────────────────────────
    // Fix 2: clearRoute — generation bump, arrived handling, navigating guard
    // ─────────────────────────────────────────────

    func testClearRoute_BumpsActiveRouteGeneration() {
        // Put in preview, record generation
        session.setRoutePreview(route)
        let genBefore = session.activeRouteGeneration

        session.clearRoute()

        XCTAssertGreaterThan(session.activeRouteGeneration, genBefore,
                             "clearRoute must increment activeRouteGeneration")
        XCTAssertNil(session.activeRoute)
        XCTAssertEqual(session.state, .idle)
    }

    func testClearRoute_FromArrived_ReturnsToIdle() {
        // Deterministically reach .arrived using fresh session and destination sample
        let freshSession = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        freshSession.startNavigation(route: route, destination: dest)

        let destLoc = makeLocation(lat: destCoord.latitude, lon: destCoord.longitude, accuracy: 5.0)
        freshSession.ingestLocation(destLoc)

        // Non-vacuous assertion: verify state reached .arrived without early returns or guards
        XCTAssertEqual(freshSession.state, .arrived, "Session must deterministically arrive at destination")

        let genBefore = freshSession.activeRouteGeneration
        freshSession.clearRoute()

        XCTAssertEqual(freshSession.state, .idle, "clearRoute from .arrived must transition to .idle")
        XCTAssertNil(freshSession.activeRoute, "activeRoute must be nil after clearRoute")
        XCTAssertEqual(freshSession.activeRouteGeneration, genBefore + 1, "Route generation must increment by 1")
    }

    func testClearRoute_WhileNavigating_IsNoOp() {
        session.startNavigation(route: route, destination: dest)
        let stateBefore      = session.state
        let routeBefore      = session.activeRoute?.totalDistanceMeters
        let sessionGenBefore = session.sessionGeneration
        let routeGenBefore   = session.activeRouteGeneration

        session.clearRoute()

        XCTAssertEqual(session.state, stateBefore, "clearRoute must be no-op while .navigating")
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, routeBefore,
                       "Active route must be preserved")
        XCTAssertEqual(session.sessionGeneration, sessionGenBefore, "Session generation must not change")
        XCTAssertEqual(session.activeRouteGeneration, routeGenBefore, "Route generation must not change")
    }

    // ─────────────────────────────────────────────
    // Fix 3: replaceActiveRoute — clears isRerouting, clears snapped location & reprojects
    // ─────────────────────────────────────────────

    func testRerouteCommit_ClearsNavSessionIsRerouting() {
        session.startNavigation(route: route, destination: dest)
        session.setRerouting(true)
        XCTAssertTrue(session.isRerouting)

        let routeB = makeRoute(from: startCoord, to: destCoord, distance: 600, name: "Route B")
        session.replaceActiveRoute(routeB)

        XCTAssertFalse(session.isRerouting,
                       "replaceActiveRoute must clear isRerouting atomically with the route commit")
    }

    func testRerouteCommit_ClearsStaleMatchedLocation_AndReprojectsImmediately() throws {
        // Construct Route A (North-South along lon 105.8540)
        let routeACoordStart = CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8540)
        let routeACoordEnd   = CLLocationCoordinate2D(latitude: 21.0400, longitude: 105.8540)
        let routeA = NavRoute(
            coordinates: [routeACoordStart, routeACoordEnd],
            steps: [
                NavStep(coordinate: routeACoordEnd, distanceMeters: 1110, durationSeconds: 110,
                        streetName: "Route A Street", maneuverType: .straight, instruction: "Drive North")
            ],
            totalDistanceMeters: 1110, totalDurationSeconds: 110
        )

        session.startNavigation(route: routeA, destination: dest)

        // Vehicle moves to physical location P off Route A at (21.0350, 105.8600) (~600m east)
        let locP = makeLocation(lat: 21.0350, lon: 105.8600, accuracy: 5.0)
        session.ingestLocation(locP)

        let oldProjection = try XCTUnwrap(session.currentProjection)
        XCTAssertEqual(oldProjection.coordinate.longitude, 105.8540, accuracy: 0.001,
                       "Route A projection must lock to Route A longitude")

        // Construct Route B (West-East along lat 21.0350, passing through locP)
        let routeBCoordStart = CLLocationCoordinate2D(latitude: 21.0350, longitude: 105.8500)
        let routeBCoordMid   = CLLocationCoordinate2D(latitude: 21.0350, longitude: 105.8600)
        let routeBCoordEnd   = CLLocationCoordinate2D(latitude: 21.0350, longitude: 105.8700)
        let routeB = NavRoute(
            coordinates: [routeBCoordStart, routeBCoordMid, routeBCoordEnd],
            steps: [
                NavStep(coordinate: routeBCoordEnd, distanceMeters: 2000, durationSeconds: 200,
                        streetName: "Route B Eastway", maneuverType: .arrive, instruction: "Arrive on Route B")
            ],
            totalDistanceMeters: 2000, totalDurationSeconds: 200
        )

        var progressUpdated = false
        session.onProgressUpdate = { _ in progressUpdated = true }

        // Act: replace active route with Route B
        session.replaceActiveRoute(routeB)

        // Assert: invariants required by P5.1
        XCTAssertEqual(session.activeRoute?.totalDistanceMeters, 2000, "Active route must be Route B")
        XCTAssertNotNil(session.currentProjection, "currentProjection must exist immediately after replaceActiveRoute")
        XCTAssertNotNil(session.matchedLocation, "matchedLocation must exist immediately after replaceActiveRoute")
        XCTAssertNotNil(session.snappedLocation, "snappedLocation must exist immediately after replaceActiveRoute")
        XCTAssertTrue(progressUpdated, "onProgressUpdate must fire immediately upon route replacement")

        // Current projection must belong to Route B geometry (near locP longitude 105.8600, NOT Route A 105.8540)
        let newProjCoord = session.currentProjection!.coordinate
        XCTAssertEqual(newProjCoord.latitude, 21.0350, accuracy: 0.001,
                       "Projection must lie on Route B latitude")
        XCTAssertEqual(newProjCoord.longitude, 105.8600, accuracy: 0.001,
                       "Projection must match physical location along Route B geometry")
        XCTAssertNotEqual(newProjCoord.longitude, oldProjection.coordinate.longitude,
                          "Old Route A projection must not be retained")
        XCTAssertEqual(session.activeProgress.nextStreetName, "Route B Eastway",
                       "Active progress must correspond to Route B")
    }

    // ─────────────────────────────────────────────
    // Fix 5: Arrival tracking profile downgrade (Deterministic & Non-Vacuous)
    // ─────────────────────────────────────────────

    func testForegroundArrival_LowersTrackingProfile() {
        let freshSession = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        freshSession.startNavigation(route: route, destination: dest)
        XCTAssertEqual(freshSession.trackingProfile, .activeNavigation,
                       "Active navigation must use activeNavigation profile")

        // First accepted sample at destination triggers immediate arrival
        let destLoc = makeLocation(lat: destCoord.latitude, lon: destCoord.longitude, accuracy: 5.0)
        freshSession.ingestLocation(destLoc)

        // Strict non-vacuous assertions: no conditional checks or early exits
        XCTAssertEqual(freshSession.state, .arrived, "Must reach .arrived state deterministically")
        XCTAssertEqual(freshSession.trackingProfile, .foregroundPassive,
                       "Foreground arrival must downgrade immediately to foregroundPassive")
        XCTAssertFalse(freshSession.currentTrackingConfig.allowsBackgroundLocationUpdates,
                       "Foreground arrival must disable background location updates")
        XCTAssertFalse(freshSession.currentTrackingConfig.headingEnabled,
                       "Foreground arrival must disable heading")
    }

    func testBackgroundArrival_LowersTrackingProfile_ToSuspended() {
        let freshSession = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        freshSession.startNavigation(route: route, destination: dest)
        XCTAssertEqual(freshSession.trackingProfile, .activeNavigation)

        // App transitions to background while navigating
        freshSession.handleScenePhaseChange(isForeground: false)
        XCTAssertEqual(freshSession.trackingProfile, .activeNavigation,
                       "Navigation must remain activeNavigation while app is backgrounded")
        XCTAssertTrue(freshSession.currentTrackingConfig.allowsBackgroundLocationUpdates,
                      "Background navigation must keep allowsBackgroundLocationUpdates true")

        // Vehicle reaches destination while backgrounded
        let destLoc = makeLocation(lat: destCoord.latitude, lon: destCoord.longitude, accuracy: 5.0)
        freshSession.ingestLocation(destLoc)

        // Strict non-vacuous assertions
        XCTAssertEqual(freshSession.state, .arrived, "Must reach .arrived state in background")
        XCTAssertEqual(freshSession.trackingProfile, .suspended,
                       "Background arrival must immediately downgrade to suspended")
        XCTAssertFalse(freshSession.currentTrackingConfig.allowsBackgroundLocationUpdates,
                       "Background arrival must disable background location updates")
        XCTAssertFalse(freshSession.currentTrackingConfig.headingEnabled,
                       "Background arrival must disable heading")
    }

    // ─────────────────────────────────────────────
    // Fix 6: GPS accuracy threshold (20m)
    // ─────────────────────────────────────────────

    func testGPS_21m_Rejected_With_20m_Threshold() {
        session.startNavigation(route: route, destination: dest)
        let receivedBefore = session.diagnostics.locationsReceived
        let acceptedBefore = session.diagnostics.locationsAccepted

        // Inject a sample with horizontalAccuracy > 20m
        let badLoc = makeLocation(lat: 21.035, lon: 105.854, accuracy: 21.0)
        session.ingestLocation(badLoc)

        XCTAssertEqual(session.diagnostics.locationsReceived, receivedBefore + 1,
                       "Must count the ingest attempt")
        XCTAssertEqual(session.diagnostics.locationsAccepted, acceptedBefore,
                       "21m accuracy sample must be rejected with 20m threshold")
    }

    func testGPS_20m_Accepted_At_Threshold() {
        session.startNavigation(route: route, destination: dest)
        let acceptedBefore = session.diagnostics.locationsAccepted

        let goodLoc = makeLocation(lat: 21.035, lon: 105.854, accuracy: 20.0)
        session.ingestLocation(goodLoc)

        XCTAssertEqual(session.diagnostics.locationsAccepted, acceptedBefore + 1,
                       "Exactly 20m accuracy must be accepted")
    }

    // ─────────────────────────────────────────────
    // Fix 6: Arrival threshold (15m)
    // ─────────────────────────────────────────────

    func testArrival_GreaterThan15m_NotTriggered() {
        // Build a short 2-point route where the start is ~33m from dest
        let closeStart = CLLocationCoordinate2D(latitude: 21.039700, longitude: 105.854)
        let shortRoute = makeRoute(from: closeStart, to: destCoord, distance: 33)
        session.startNavigation(route: shortRoute, destination: dest)

        var arrivedFired = false
        session.onArrived = { arrivedFired = true }

        // Inject a sample at ~30m from dest — should NOT trigger arrival with 15m threshold
        let farLoc = makeLocation(lat: 21.039700, lon: 105.854, accuracy: 5.0)
        session.ingestLocation(farLoc)

        XCTAssertFalse(arrivedFired,
                       "Arrival must not trigger when physicalDist > 15m from destination")
        XCTAssertEqual(session.state, .navigating)
    }

    // ─────────────────────────────────────────────
    // P5.2.1 Regressions: Trimming, Monotonic Progress, Physical Displacement & Arrival
    // ─────────────────────────────────────────────

    func testMonotonicDisplayProgress_NoisyBackwardMatchDoesNotDecreaseProgress() {
        // Northbound route ~1113m total
        let rCoords = [
            CLLocationCoordinate2D(latitude: 21.000, longitude: 105.800),
            CLLocationCoordinate2D(latitude: 21.010, longitude: 105.800)
        ]
        let testRoute = NavRoute(
            coordinates: rCoords,
            steps: [NavStep(coordinate: rCoords[1], distanceMeters: 1113.0, durationSeconds: 100.0, streetName: "North Ave", maneuverType: .straight, instruction: "Straight")],
            totalDistanceMeters: 1113.0,
            totalDurationSeconds: 100.0
        )
        session.startNavigation(route: testRoute, destination: NavigationDestination(coordinate: rCoords[1], name: "Dest"))

        var time = Date()

        // 1. Progress to 20m, 40m, 60m along route
        for step in [0.00018, 0.00036, 0.00054] {
            time = time.addingTimeInterval(2.0)
            let loc = makeLocation(lat: 21.000 + step, lon: 105.800, accuracy: 3.0, speed: 10.0, ts: time)
            session.ingestLocation(loc)
        }

        let progressAt60 = session.displayProgressDistanceAlongRoute
        XCTAssertGreaterThanOrEqual(progressAt60, 58.0, "Progress should be around 60m")

        // 2. Inject noisy backward sample corresponding to ~35m (lat 21.000 + 0.00031)
        time = time.addingTimeInterval(1.0)
        let noisyBackwardLoc = makeLocation(lat: 21.000 + 0.00031, lon: 105.800, accuracy: 4.0, speed: 10.0, ts: time)
        session.ingestLocation(noisyBackwardLoc)

        // 3. Assert display progress did NOT regress
        XCTAssertGreaterThanOrEqual(session.displayProgressDistanceAlongRoute, progressAt60, "Display progress must be strictly non-decreasing along active route")

        // 4. Assert remaining polyline first coordinate is at or beyond 60m
        XCTAssertFalse(session.remainingPolyline.isEmpty)
        let firstRemaining = session.remainingPolyline.first!
        let distAlong = testRoute.geometry.project(location: CLLocation(latitude: firstRemaining.latitude, longitude: firstRemaining.longitude))?.distanceAlongRouteMeters ?? 0.0
        XCTAssertGreaterThanOrEqual(distAlong, 58.0, "Remaining polyline must not recreate passed route geometry")
    }

    func testPhysicalDisplacementDiagnostics_MeasuresPhysicalToPhysical() {
        session.startNavigation(route: route, destination: dest)

        let time1 = Date()
        let locA = makeLocation(lat: 21.03000, lon: 105.85400, accuracy: 3.0, speed: 5.0, ts: time1)
        session.ingestLocation(locA)

        // Move physical vehicle ~10 meters north (0.00009 deg lat ≈ 10.0m)
        let time2 = time1.addingTimeInterval(1.0)
        let locB = makeLocation(lat: 21.03009, lon: 105.85400, accuracy: 3.0, speed: 5.0, ts: time2)
        session.ingestLocation(locB)

        let displacement = session.diagnostics.latestFieldTrace?.physicalDisplacement ?? 0.0
        XCTAssertEqual(displacement, 10.0, accuracy: 1.0, "physicalDisplacement must measure physical GPS A to GPS B")
        XCTAssertEqual(session.previousAcceptedPhysicalLocation?.coordinate.latitude ?? 0, locA.coordinate.latitude, accuracy: 1e-6)
        XCTAssertEqual(session.acceptedPhysicalLocation?.coordinate.latitude ?? 0, locB.coordinate.latitude, accuracy: 1e-6)
    }

    func testArrivalMapPresentation_ClearsPolylineAndDoesNotSelectHistoricalRoute() {
        let shortRoute = makeRoute(from: startCoord, to: destCoord, distance: 20)
        session.startNavigation(route: shortRoute, destination: dest)

        // Arrive right at destination (within 5m)
        let atDestLoc = makeLocation(lat: destCoord.latitude, lon: destCoord.longitude, accuracy: 3.0)
        session.ingestLocation(atDestLoc)

        XCTAssertEqual(session.state, .arrived)
        XCTAssertTrue(session.remainingPolyline.isEmpty, "Arrival must clear remainingPolyline")

        // Check RouteMapPresentation mapping
        let presentation: RouteMapPresentation = {
            switch session.state {
            case .navigating: return .navigating
            case .routePreview: return .preview
            case .arrived: return .arrived
            case .idle: return .none
            }
        }()
        XCTAssertEqual(presentation, .arrived)
    }
}
