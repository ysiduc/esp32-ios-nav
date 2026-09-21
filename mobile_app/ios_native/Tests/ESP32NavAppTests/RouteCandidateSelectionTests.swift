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
    var lastCosting: String?

    // Controllable continuation support
    var useContinuation = false
    struct Pending {
        let destination: CLLocationCoordinate2D
        let continuation: CheckedContinuation<RouteSet, Error>
    }
    private(set) var pendings: [Pending] = []
    var pendingCount: Int { pendings.count }

    func resume(at index: Int = 0, with routeSet: RouteSet) {
        guard index < pendings.count else { return }
        let p = pendings.remove(at: index)
        p.continuation.resume(returning: routeSet)
    }

    func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        calculateRoutesCallCount += 1
        lastRequest = request

        if useContinuation {
            return try await withCheckedThrowingContinuation { cont in
                pendings.append(Pending(destination: request.destination, continuation: cont))
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
        lastCosting = costing
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
    var searchService: MockPlaceSearchService!
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
        searchService = MockPlaceSearchService()

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
        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
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
        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
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

    func testStaleRouteSetResponse_IsDiscarded() async throws {
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
        var waitCount = 0
        while service.pendingCount < 1 && waitCount < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waitCount += 1
        }
        XCTAssertEqual(service.pendingCount, 1)

        // Immediately start request 2 which supersedes request 1
        let t2 = Task { await vm.calculateRoute(to: dest2) }
        waitCount = 0
        while service.pendingCount < 2 && waitCount < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waitCount += 1
        }
        XCTAssertEqual(service.pendingCount, 2)

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
        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        await viewModel.calculateRoute(to: coordB)
        viewModel.startNavigation()
        XCTAssertEqual(navSession.state, .navigating)

        viewModel.stopNavigation()

        XCTAssertEqual(navSession.state, .idle)
        XCTAssertTrue(viewModel.routeCandidates.isEmpty)
        XCTAssertNil(viewModel.selectedRouteCandidateID)
    }
    // MARK: - 7. Mode Switch Preview Success

    func testModeSwitchPreviewSuccess_ImmediatelyInvalidatesOldAndInstallsNewCandidates() async {
        // Setup initial Motorcycle routes
        await viewModel.calculateRoute(to: coordB)
        XCTAssertEqual(viewModel.currentTransportMode, .motorcycle)
        XCTAssertEqual(viewModel.routeCandidates.count, 3)
        XCTAssertEqual(viewModel.selectedRouteCandidateID, "c0")

        // Prepare auto route return
        let rAuto = NavRoute(coordinates: [coordA, coordB], steps: [], totalDistanceMeters: 2000, totalDurationSeconds: 300)
        let autoCand = RouteCandidate(id: "auto_c0", route: rAuto, provider: .valhalla, requestedMode: .auto, profileID: "auto_standard", isPrimary: true, label: "Đề xuất")
        mockRouting.routeSetToReturn = RouteSet(candidates: [autoCand])

        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        // User switches mode to auto
        viewModel.transportMode = "auto"
        viewModel.recalculateForTransportMode()

        // Wait briefly for Task in recalculateForTransportMode to complete
        for _ in 0..<50 {
            if viewModel.selectedRouteCandidateID == "auto_c0" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(viewModel.currentTransportMode, .auto)
        XCTAssertEqual(viewModel.routeCandidates.count, 1)
        XCTAssertEqual(viewModel.selectedRouteCandidateID, "auto_c0")
        XCTAssertEqual(viewModel.routeCandidates.first?.requestedMode, .auto)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 2000)
    }

    // MARK: - 8. Mode Switch Preview Failure

    func testModeSwitchPreviewFailure_LeavesCleanStateAndDoesNotResurrectOldRoute() async {
        // 1. Initial Motorcycle preview succeeds
        await viewModel.calculateRoute(to: coordB)
        XCTAssertEqual(viewModel.routeCandidates.count, 3)
        XCTAssertNotNil(navSession.activeRoute)

        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        // 2. Next routing call (for auto) will fail
        mockRouting.routeSetToReturn = nil

        // 3. User switches to Auto
        viewModel.transportMode = "auto"
        viewModel.recalculateForTransportMode()

        for _ in 0..<50 {
            if viewModel.routeErrorMessage != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // 4. Assert full cleanup and NO resurrection of old Motorcycle route
        XCTAssertEqual(viewModel.currentTransportMode, .auto)
        XCTAssertTrue(viewModel.routeCandidates.isEmpty)
        XCTAssertNil(viewModel.selectedRouteCandidateID)
        XCTAssertNil(navSession.activeRoute, "Old motorcycle route preview must not be resurrected")
        XCTAssertFalse(viewModel.isCalculatingRoute)
        XCTAssertNotNil(viewModel.routeErrorMessage)

        // 5. User tapping start navigation must NOT start navigation
        viewModel.startNavigation()
        XCTAssertEqual(navSession.state, .idle, "startNavigation must be rejected after failed mode switch")
    }

    // MARK: - 9. Start Navigation Wrong Mode Rejected

    func testStartNavigation_WrongModeRejected() async {
        // User selects auto mode
        viewModel.transportMode = "auto"

        // Mock routing service returns candidate with requestedMode == .motorcycle
        let r0 = NavRoute(coordinates: [coordA, coordB], steps: [], totalDistanceMeters: 1000, totalDurationSeconds: 120)
        let mismatchCandidate = RouteCandidate(
            id: "mismatch_c0",
            route: r0,
            provider: .valhalla,
            requestedMode: .motorcycle,
            profileID: "moto_p",
            isPrimary: true,
            label: "Đề xuất"
        )
        mockRouting.routeSetToReturn = RouteSet(candidates: [mismatchCandidate])

        await viewModel.calculateRoute(to: coordB)

        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        XCTAssertEqual(viewModel.currentTransportMode, .auto)
        XCTAssertEqual(viewModel.routeCandidates.first?.requestedMode, .motorcycle)

        viewModel.startNavigation()

        XCTAssertNotEqual(navSession.state, .navigating, "startNavigation must reject mode mismatch and not navigate")
        XCTAssertEqual(navSession.state, .routePreview, "Session remains in routePreview")
        XCTAssertNotNil(viewModel.routeErrorMessage)
    }

    // MARK: - 10. Clear Search Resets IsCalculatingRoute

    func testClearSearch_ResetsIsCalculatingRoute() async throws {
        let service = ControlledMockRoutingService()
        let vm = NavigationViewModel(
            routingService: service,
            navSession: navSession,
            searchService: searchService,
            bleManager: nil
        )

        let t = Task { await vm.calculateRoute(to: coordB) }
        var wait = 0
        while service.pendingCount < 1 && wait < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            wait += 1
        }
        XCTAssertTrue(vm.isCalculatingRoute)

        // User clears search while route request is pending
        vm.clearSearch()

        XCTAssertFalse(vm.isCalculatingRoute, "clearSearch must immediately reset isCalculatingRoute to false")
        XCTAssertTrue(vm.routeCandidates.isEmpty)
        XCTAssertNil(vm.selectedRouteCandidateID)
        XCTAssertNil(navSession.activeRoute)

        // Late response arrives
        service.resume(destination: coordB, with: RouteSet(candidates: [candidate0]))
        await t.value

        XCTAssertFalse(vm.isCalculatingRoute)
        XCTAssertTrue(vm.routeCandidates.isEmpty)
        XCTAssertNil(navSession.activeRoute)
    }

    // MARK: - 11. New Search Resets IsCalculatingRoute

    func testNewSearch_ResetsIsCalculatingRoute() async throws {
        let service = ControlledMockRoutingService()
        let vm = NavigationViewModel(
            routingService: service,
            navSession: navSession,
            searchService: searchService,
            bleManager: nil
        )

        let t = Task { await vm.calculateRoute(to: coordB) }
        var wait = 0
        while service.pendingCount < 1 && wait < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            wait += 1
        }
        XCTAssertTrue(vm.isCalculatingRoute)

        // User types new query
        vm.updateSearchQuery("New query")

        XCTAssertFalse(vm.isCalculatingRoute, "updateSearchQuery with new intent must reset isCalculatingRoute")
        XCTAssertTrue(vm.routeCandidates.isEmpty)
        XCTAssertNil(navSession.activeRoute)

        service.resume(destination: coordB, with: RouteSet(candidates: [candidate0]))
        await t.value

        XCTAssertFalse(vm.isCalculatingRoute)
        XCTAssertTrue(vm.routeCandidates.isEmpty)
    }

    // MARK: - 12. Select Prediction Clears Old RouteSet Immediately

    func testSelectPrediction_ClearsOldRouteSetImmediately() async {
        let searchSvc = MockPlaceSearchService()
        searchSvc.useContinuationForDetail = true
        let vm = NavigationViewModel(
            routingService: mockRouting,
            navSession: navSession,
            searchService: searchSvc,
            bleManager: nil
        )

        // Mock routing service returns RouteSet naturally through calculateRoute
        mockRouting.routeSetToReturn = RouteSet(candidates: [candidate0, candidate1])
        await vm.calculateRoute(to: coordB)

        XCTAssertEqual(vm.routeCandidates.count, 2)
        XCTAssertEqual(vm.selectedRouteCandidateID, "c0")
        XCTAssertNotNil(navSession.activeRoute)

        let pred = SearchPrediction(id: "p2", title: "New Destination", subtitle: "")

        vm.selectPrediction(pred)

        // Candidate state must be cleared IMMEDIATELY, before place detail returns
        XCTAssertTrue(vm.routeCandidates.isEmpty, "selectPrediction must immediately clear routeCandidates")
        XCTAssertNil(vm.selectedRouteCandidateID, "selectPrediction must immediately clear selectedRouteCandidateID")
        XCTAssertNil(navSession.activeRoute, "selectPrediction must immediately clear activeRoute preview")
    }

    // MARK: - 13. Place Detail Failure Resets IsCalculatingRoute And Cleans Preview

    func testPlaceDetailFailure_ResetsIsCalculatingRouteAndCleansPreview() async throws {
        let searchSvc = MockPlaceSearchService()
        searchSvc.resolveResult = .failure(URLError(.cannotConnectToHost))
        let vm = NavigationViewModel(
            routingService: mockRouting,
            navSession: navSession,
            searchService: searchSvc,
            bleManager: nil
        )

        let pred = SearchPrediction(id: "fail_p", title: "Failing Place", subtitle: "")

        vm.selectPrediction(pred)

        for _ in 0..<50 {
            if vm.routeErrorMessage != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(vm.isCalculatingRoute)
        XCTAssertTrue(vm.routeCandidates.isEmpty)
        XCTAssertNil(vm.selectedRouteCandidateID)
        XCTAssertNil(navSession.activeRoute)
        XCTAssertNotNil(vm.routeErrorMessage)
    }

    // MARK: - 14. Superseded Route A Cannot Clear Route B Loading State

    func testSupersededRouteA_CannotClearRouteBLoadingState() async throws {
        let service = ControlledMockRoutingService()
        let vm = NavigationViewModel(
            routingService: service,
            navSession: navSession,
            searchService: searchService,
            bleManager: nil
        )

        let dest1 = CLLocationCoordinate2D(latitude: 21.1, longitude: 105.8)
        let dest2 = CLLocationCoordinate2D(latitude: 21.2, longitude: 105.9)

        let t1 = Task { await vm.calculateRoute(to: dest1) }
        var wait = 0
        while service.pendingCount < 1 && wait < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            wait += 1
        }
        XCTAssertTrue(vm.isCalculatingRoute)

        // Request 2 starts and supersedes Request 1
        let t2 = Task { await vm.calculateRoute(to: dest2) }
        wait = 0
        while service.pendingCount < 2 && wait < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            wait += 1
        }
        XCTAssertTrue(vm.isCalculatingRoute)

        // Cancel/resume Request 1 late with error or result
        service.resume(destination: dest1, with: RouteSet(candidates: [candidate0]))
        await t1.value

        // Request 2 is still in flight: isCalculatingRoute MUST remain true!
        XCTAssertTrue(vm.isCalculatingRoute, "Cancelled/unwound Request 1 must NOT set isCalculatingRoute to false while Request 2 is active")

        // Finish Request 2
        service.resume(destination: dest2, with: RouteSet(candidates: [candidate1]))
        await t2.value

        XCTAssertFalse(vm.isCalculatingRoute)
        XCTAssertEqual(vm.selectedRouteCandidateID, "c1")
    }

    // MARK: - 15. Select Route Candidate Ignored During Active Navigation

    func testSelectRouteCandidate_IgnoredDuringActiveNavigation() async {
        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        await viewModel.calculateRoute(to: coordB)
        viewModel.startNavigation()
        XCTAssertEqual(navSession.state, .navigating)
        let originalSessionGen = navSession.sessionGeneration
        let originalDist = navSession.activeRoute?.totalDistanceMeters

        // Tapping an alternative while navigating must be ignored
        viewModel.selectRouteCandidate(id: "c1")

        XCTAssertEqual(navSession.state, .navigating)
        XCTAssertEqual(navSession.sessionGeneration, originalSessionGen)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, originalDist, "selectRouteCandidate must not alter active navigation route")
    }

    // MARK: - 16. Mode Switch While Navigating Preserves Route and Triggers Reroute

    func testTransportModeSwitch_WhileNavigating_PreservesActiveRouteAndTriggersReroute() async {
        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        await viewModel.calculateRoute(to: coordB)
        viewModel.startNavigation()
        XCTAssertEqual(navSession.state, .navigating)
        let activeDist = navSession.activeRoute?.totalDistanceMeters

        // User changes transport mode while actively navigating
        viewModel.transportMode = "auto"
        viewModel.recalculateForTransportMode()

        // Active route MUST NOT be cleared immediately; remains active until reroute replaces it
        XCTAssertEqual(navSession.state, .navigating)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, activeDist, "Active navigation route must remain while transport mode reroute is in flight")
    }

    // MARK: - 17. Transport Mode Switch While Navigating Commits New Route

    func testTransportModeSwitch_WhileNavigating_CommitsNewRoute() async throws {
        // 1. Initial preview route A (motorcycle)
        await viewModel.calculateRoute(to: coordB)

        let testDest = ResolvedPlace(id: "test_dest", name: "Destination", formattedAddress: "Hanoi", coordinate: coordB)
        viewModel.selectedDestination = testDest

        // 2. Start navigation on Route A
        viewModel.startNavigation()
        XCTAssertEqual(navSession.state, .navigating)
        let initialSessionGen = navSession.sessionGeneration
        let initialDist = navSession.activeRoute?.totalDistanceMeters
        let initialDestName = navSession.navigationDestination?.name
        XCTAssertEqual(initialDestName, "Hồ Gươm")

        // 3. Configure next routing request (reroute) to remain pending
        mockRouting.useContinuation = true

        // 4. User selects Auto and triggers transport mode recalculation
        viewModel.transportMode = "auto"
        viewModel.recalculateForTransportMode()

        // Wait for reroute task to dispatch and suspend in routing service
        var wait = 0
        while mockRouting.pendingCount < 1 && wait < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            wait += 1
        }
        XCTAssertEqual(mockRouting.pendingCount, 1)

        // 5. Immediately verify:
        //    - state == .navigating
        //    - activeRoute == Motorcycle A (NOT cleared!)
        //    - navigationDestination unchanged
        //    - costing == "auto" and requestedAlternatives == 0
        XCTAssertEqual(navSession.state, .navigating)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, initialDist, "Motorcycle Route A remains active while Auto reroute is in flight")
        XCTAssertEqual(navSession.navigationDestination?.name, initialDestName)
        XCTAssertEqual(mockRouting.lastCosting, "auto")
        XCTAssertEqual(mockRouting.lastRequest?.requestedAlternatives, 0, "Reroute must request 0 alternatives")

        // 6. Explicitly resolve the pending request with Auto Route B
        let autoRouteB = NavRoute(
            coordinates: [coordA, CLLocationCoordinate2D(latitude: 21.035, longitude: 105.845), coordB],
            steps: [],
            totalDistanceMeters: 2500,
            totalDurationSeconds: 400
        )
        let autoCandidateB = RouteCandidate(
            id: "auto_b",
            route: autoRouteB,
            provider: .valhalla,
            requestedMode: .auto,
            profileID: "auto_standard",
            isPrimary: true
        )
        mockRouting.resume(at: 0, with: RouteSet(candidates: [autoCandidateB]))

        // 7. Wait deterministically for reroute to commit
        for _ in 0..<50 {
            if navSession.activeRoute?.totalDistanceMeters == 2500 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // 8. Final assertions:
        XCTAssertEqual(navSession.state, .navigating)
        XCTAssertEqual(navSession.activeRoute?.totalDistanceMeters, 2500, "Active route must atomically become Auto Route B")
        XCTAssertEqual(navSession.navigationDestination?.name, initialDestName, "Navigation destination must remain unchanged")
        XCTAssertEqual(navSession.sessionGeneration, initialSessionGen, "Session generation must remain unchanged")
        XCTAssertEqual(viewModel.currentTransportMode, .auto)
        XCTAssertEqual(viewModel.routeCandidates.count, 3, "Preview route candidates must not be modified or replaced by reroute")
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
    var pendingCount: Int { pendings.count }

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
