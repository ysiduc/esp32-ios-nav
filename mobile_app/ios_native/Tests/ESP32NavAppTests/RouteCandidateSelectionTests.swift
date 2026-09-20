//
//  RouteCandidateSelectionTests.swift
//  Unit tests for NavigationViewModel preview candidate selection lifecycle,
//  candidate switching, startNavigation on alternative route, and race safety.
//

import XCTest
import CoreLocation
@testable import ESP32NavApp

// MARK: - Mock Multi-Route Service

@MainActor
final class MockMultiRouteService: RoutingServiceProtocol {
    var routeSetToReturn: RouteSet?
    var calculateRoutesCallCount = 0
    var lastRequest: RoutingRequest?

    // Controllable continuation for race testing
    var pendingContinuation: CheckedContinuation<RouteSet, Error>?

    func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        calculateRoutesCallCount += 1
        lastRequest = request

        if let cont = pendingContinuation {
            return try await withCheckedThrowingContinuation { c in
                self.pendingContinuation = c
            }
        }

        if let set = routeSetToReturn {
            return set
        }

        throw ValhallaRoutingError.noRouteFound("No test route set provided")
    }

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        let set = try await calculateRoutes(
            request: RoutingRequest(
                origin: origin,
                destination: destination,
                profile: RoutingProfile.profile(for: NavigationTransportMode(costingValue: costing)),
                requestedAlternatives: 0
            )
        )
        guard let primary = set.primaryRoute else {
            throw ValhallaRoutingError.noRouteFound("No route")
        }
        return primary
    }
}

// MARK: - Test Suite

@MainActor
final class RouteCandidateSelectionTests: XCTestCase {

    var mockRouting: MockMultiRouteService!
    var navSession: NavigationSessionManager!
    var searchService: GoongSearchService!
    var viewModel: NavigationViewModel!

    let coordA = CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542)
    let coordB = CLLocationCoordinate2D(latitude: 21.0368, longitude: 105.8346)

    var candidate0: RouteCandidate!
    var candidate1: RouteCandidate!
    var candidate2: RouteCandidate!

    override func setUp() async throws {
        mockRouting = MockMultiRouteService()
        navSession = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        navSession.userLocation = CLLocation(latitude: coordA.latitude, longitude: coordA.longitude)
        searchService = GoongSearchService(client: MockGoongPlacesClient(), debounceDelay: 0)

        viewModel = NavigationViewModel(
            routingService: mockRouting,
            navSession: navSession,
            searchService: searchService,
            bleManager: nil
        )

        let r0 = NavRoute(coordinates: [coordA, coordB], steps: [], totalDistanceMeters: 1000, totalDurationSeconds: 120)
        let r1 = NavRoute(coordinates: [coordA, CLLocationCoordinate2D(latitude: 21.03, longitude: 105.84), coordB], steps: [], totalDistanceMeters: 1200, totalDurationSeconds: 150)
        let r2 = NavRoute(coordinates: [coordA, CLLocationCoordinate2D(latitude: 21.04, longitude: 105.85), coordB], steps: [], totalDistanceMeters: 1500, totalDurationSeconds: 180)

        candidate0 = RouteCandidate(id: "c0", route: r0, provider: .valhalla, requestedMode: .motorcycle, profileID: "p0", isPrimary: true, label: "Đề xuất")
        candidate1 = RouteCandidate(id: "c1", route: r1, provider: .valhalla, requestedMode: .motorcycle, profileID: "p0", isPrimary: false, label: "Tuyến 2")
        candidate2 = RouteCandidate(id: "c2", route: r2, provider: .valhalla, requestedMode: .motorcycle, profileID: "p0", isPrimary: false, label: "Tuyến 3")

        mockRouting.routeSetToReturn = RouteSet(candidates: [candidate0, candidate1, candidate2])
    }

    // MARK: - 1. Default Selection

    func testDefaultSelection_SelectsPrimaryCandidate() async {
        await viewModel.calculateRoute(to: coordB)

        XCTAssertEqual(viewModel.routeCandidates.count, 3)
        XCTAssertEqual(viewModel.selectedRouteCandidateID, "c0")
        XCTAssertEqual(viewModel.currentRoutingProvider, .valhalla)
        XCTAssertFalse(viewModel.isDegradedRoute)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 1000)
    }

    // MARK: - 2. Select Alternative Candidate

    func testUserSelectsAlternative_SwitchesPreviewWithoutMutatingDestinationOrSession() async {
        let testDest = GoongPlace(
            placeID: "dest_1",
            name: "Hồ Gươm",
            formattedAddress: "Hà Nội",
            location: CLLocation(latitude: coordB.latitude, longitude: coordB.longitude)
        )
        viewModel.selectedDestination = testDest

        await viewModel.calculateRoute(to: coordB)

        let initialSessionGen = navSession.sessionGeneration

        // User switches from primary (c0) to alternative (c1)
        viewModel.selectRouteCandidate(id: "c1")

        XCTAssertEqual(viewModel.selectedRouteCandidateID, "c1")
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 1200)
        XCTAssertEqual(navSession.activeRoute?.totalDurationSeconds, 150)

        // Must NOT mutate destination or session identity
        XCTAssertEqual(viewModel.selectedDestination?.placeID, "dest_1")
        XCTAssertEqual(navSession.sessionGeneration, initialSessionGen)
    }

    // MARK: - 3. Start Navigation with Selected Alternative

    func testStartNavigation_UsesSelectedCandidateAlternative() async {
        let testDest = GoongPlace(
            placeID: "dest_1",
            name: "Hồ Gươm",
            formattedAddress: "Hà Nội",
            location: CLLocation(latitude: coordB.latitude, longitude: coordB.longitude)
        )
        viewModel.selectedDestination = testDest

        await viewModel.calculateRoute(to: coordB)

        // Select candidate 1 (not primary candidate 0)
        viewModel.selectRouteCandidate(id: "c1")

        // Start Navigation
        viewModel.startNavigation()

        XCTAssertEqual(navSession.state, .navigating)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 1200, "Should navigate on candidate 1, not candidate 0")
        XCTAssertEqual(navSession.navigationDestination?.name, "Hồ Gươm")
    }

    // MARK: - 4. Stale RouteSet Response Discarded

    func testStaleRouteSetResponse_IsDiscarded() async {
        // Slow request 1
        let service = ControlledMockRoutingService()
        let vm = NavigationViewModel(
            routingService: service,
            navSession: navSession,
            searchService: searchService,
            bleManager: nil
        )

        let dest1 = CLLocationCoordinate2D(latitude: 21.1, longitude: 105.8)
        let dest2 = CLLocationCoordinate2D(latitude: 21.2, longitude: 105.9)

        // Start request 1 (async)
        let t1 = Task { await vm.calculateRoute(to: dest1) }

        // Immediately start request 2 which supersedes request 1
        let t2 = Task { await vm.calculateRoute(to: dest2) }

        // Resume request 2 first with fast result
        let fastSet = RouteSet(candidates: [candidate1])
        service.resume(destination: dest2, with: fastSet)
        await t2.value

        XCTAssertEqual(vm.routeCandidates.count, 1)
        XCTAssertEqual(vm.selectedRouteCandidateID, "c1")

        // Resume request 1 late with slow result
        let slowSet = RouteSet(candidates: [candidate0, candidate2])
        service.resume(destination: dest1, with: slowSet)
        await t1.value

        // Request 1 must be discarded; candidate 1 remains
        XCTAssertEqual(vm.routeCandidates.count, 1)
        XCTAssertEqual(vm.selectedRouteCandidateID, "c1")
    }

    // MARK: - 5. Clear Search Clears Candidates

    func testClearSearch_ClearsCandidateState() async {
        await viewModel.calculateRoute(to: coordB)
        XCTAssertEqual(viewModel.routeCandidates.count, 3)

        viewModel.clearSearch()

        XCTAssertTrue(viewModel.routeCandidates.isEmpty)
        XCTAssertNil(viewModel.selectedRouteCandidateID)
        XCTAssertNil(viewModel.currentRoutingProvider)
        XCTAssertFalse(viewModel.isDegradedRoute)
    }

    // MARK: - 6. Stop Navigation Clears Candidates

    func testStopNavigation_ClearsCandidateState() async {
        let testDest = GoongPlace(
            placeID: "dest_1",
            name: "Hồ Gươm",
            formattedAddress: "Hà Nội",
            location: CLLocation(latitude: coordB.latitude, longitude: coordB.longitude)
        )
        viewModel.selectedDestination = testDest

        await viewModel.calculateRoute(to: coordB)
        viewModel.startNavigation()
        XCTAssertEqual(navSession.state, .navigating)

        viewModel.stopNavigation()

        XCTAssertEqual(navSession.state, .idle)
        XCTAssertTrue(viewModel.routeCandidates.isEmpty)
        XCTAssertNil(viewModel.selectedRouteCandidateID)
    }
}

// MARK: - Controlled Mock for Race Testing

@MainActor
final class ControlledMockRoutingService: RoutingServiceProtocol {
    struct Pending {
        let destination: CLLocationCoordinate2D
        let continuation: CheckedContinuation<RouteSet, Error>
    }
    private var pendings: [Pending] = []

    func resume(destination: CLLocationCoordinate2D, with routeSet: RouteSet) {
        if let idx = pendings.firstIndex(where: { abs($0.destination.latitude - destination.latitude) < 1e-5 }) {
            let p = pendings.remove(at: idx)
            p.continuation.resume(returning: routeSet)
        }
    }

    func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        return try await withCheckedThrowingContinuation { cont in
            pendings.append(Pending(destination: request.destination, continuation: cont))
        }
    }

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        let set = try await calculateRoutes(
            request: RoutingRequest(
                origin: origin,
                destination: destination,
                profile: RoutingProfile.profile(for: NavigationTransportMode(costingValue: costing)),
                requestedAlternatives: 0
            )
        )
        guard let primary = set.primaryRoute else {
            throw ValhallaRoutingError.noRouteFound("No route")
        }
        return primary
    }
}
