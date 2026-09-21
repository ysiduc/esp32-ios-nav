//
//  RerouteManager.swift
//  Coordinates rerouting policy, backoff retries, single-flight requests, and generation safety.
//

import CoreLocation
import Foundation

public enum RerouteReason: String, Sendable, Equatable {
    case offRoute
    case transportModeChanged
}

@MainActor
public final class RerouteManager: ObservableObject {

    public typealias NowProvider = @Sendable () -> Date

    // MARK: - Dependencies

    public let routingService: RoutingServiceProtocol
    public weak var navSession: NavigationSessionManager?
    private let now: NowProvider

    // MARK: - Published State

    @Published public private(set) var isRerouting: Bool = false
    @Published public private(set) var failureCount: Int = 0
    @Published public private(set) var nextEligibleRerouteAt: Date?
    @Published public private(set) var lastCommittedAt: Date?
    @Published public private(set) var currentReason: RerouteReason?

    // MARK: - Internal Lifecycle & Concurrency State

    public private(set) var rerouteRequestGeneration: UInt64 = 0
    private var activeTask: Task<NavRoute, Error>?

    // MARK: - Configurable Policy Constants

    /// Bounded retry backoff progression (seconds): 2s, 4s, 8s, 15s max.
    public let backoffDelays: [Double] = [2.0, 4.0, 8.0, 15.0]
    /// Short stabilization window after Route B installation to allow GPS to settle.
    public let postSuccessStabilizationSeconds: Double = 2.0

    // MARK: - Initialization

    public init(
        routingService: RoutingServiceProtocol,
        navSession: NavigationSessionManager? = nil,
        now: @escaping NowProvider = { Date() }
    ) {
        self.routingService = routingService
        self.navSession = navSession
        self.now = now
    }

    // MARK: - Observation Handling (Called on each location pipeline decision)

    public func handleObservation(
        location: CLLocation,
        decision: OffRouteDecision,
        costing: String = "motorcycle",
        currentTime: Date? = nil
    ) {
        let obsTime = currentTime ?? now()

        // 1. Recovery handling: if user returned to route, cancel pending off-route reroute
        if decision.recovered {
            if isRerouting && currentReason == .offRoute {
                print("[RerouteManager] User recovered to route before reroute completed — cancelling in-flight request")
                invalidateActiveRequest()
            }
            failureCount = 0
            nextEligibleRerouteAt = nil
            return
        }

        // 2. Off-route handling
        guard decision.state == .confirmed else { return }

        // Prevent duplicate concurrent requests (Single in-flight request guarantee)
        guard !isRerouting else {
            return
        }

        // Check backoff eligibility against observation time
        if let nextAt = nextEligibleRerouteAt, obsTime < nextAt {
            return
        }

        // Check post-success stabilization window against observation time
        if let lastCommitted = lastCommittedAt,
           obsTime.timeIntervalSince(lastCommitted) < postSuccessStabilizationSeconds {
            return
        }

        // Trigger observation-driven reroute using fresh physical coordinates
        startReroute(
            reason: .offRoute,
            origin: location.coordinate,
            costing: costing
        )
    }

    // MARK: - User-Authoritative Transport Mode Recalculation

    public func requestTransportModeReroute(
        costing: String,
        origin: CLLocationCoordinate2D? = nil,
        currentTime: Date? = nil
    ) {
        guard let session = navSession, session.state == .navigating else { return }
        guard let resolvedOrigin = origin ?? session.filteredLocation?.coordinate ?? session.userLocation?.coordinate else {
            print("[RerouteManager] Cannot recalculate transport mode: no GPS coordinate available")
            return
        }

        // User action supersedes any in-flight off-route reroute
        if isRerouting {
            invalidateActiveRequest()
        }

        // Transport mode change bypasses off-route backoff delay
        nextEligibleRerouteAt = nil

        startReroute(
            reason: .transportModeChanged,
            origin: resolvedOrigin,
            costing: costing
        )
    }

    // MARK: - Core Reroute Request Lifecycle

    public func startReroute(
        reason: RerouteReason,
        origin: CLLocationCoordinate2D,
        costing: String
    ) {
        guard let session = navSession, session.state == .navigating else {
            print("[RerouteManager] Skipping reroute: navigation session not active")
            return
        }
        guard let destination = session.navigationDestination else {
            print("[RerouteManager] Skipping reroute: no active navigation destination")
            return
        }

        // Invalidate any previous task before starting a new one
        invalidateActiveRequest()

        // Allocate a new request generation and capture state
        rerouteRequestGeneration &+= 1
        let capturedRerouteGen = rerouteRequestGeneration
        let capturedSessionGen = session.sessionGeneration
        let capturedRouteGen = session.activeRouteGeneration

        isRerouting = true
        currentReason = reason
        session.setRerouting(true)

        print("[RerouteManager] 🔄 Starting reroute (\(reason.rawValue)) session=\(capturedSessionGen), routeRev=\(capturedRouteGen), reqGen=\(capturedRerouteGen)")

        let task = Task<NavRoute, Error> {
            try Task.checkCancellation()
            let route = try await self.routingService.calculateRoute(
                from: origin,
                to: destination.coordinate,
                costing: costing
            )
            try Task.checkCancellation()
            return route
        }
        activeTask = task

        Task {
            do {
                let newRoute = try await task.value

                // Concurrency & generation validation
                guard !Task.isCancelled else {
                    print("[RerouteManager] Reroute task cancelled")
                    return
                }
                guard let s = self.navSession, s.state == .navigating else {
                    print("[RerouteManager] Discarding response: navigation session no longer active")
                    return
                }
                guard s.sessionGeneration == capturedSessionGen else {
                    print("[RerouteManager] Discarding response: session changed (\(capturedSessionGen) != \(s.sessionGeneration))")
                    return
                }
                guard s.activeRouteGeneration == capturedRouteGen else {
                    print("[RerouteManager] Discarding response: active route revision changed (\(capturedRouteGen) != \(s.activeRouteGeneration))")
                    return
                }
                guard self.rerouteRequestGeneration == capturedRerouteGen else {
                    print("[RerouteManager] Discarding response: superseded request (\(capturedRerouteGen) != \(self.rerouteRequestGeneration))")
                    return
                }

                // Successful commit: atomically replace active route
                s.replaceActiveRoute(newRoute)
                // Ensure navSession.isRerouting is cleared even if replaceActiveRoute
                // already cleared it internally (belt-and-suspenders).
                s.setRerouting(false)

                let commitTime = self.now()
                self.failureCount = 0
                self.nextEligibleRerouteAt = nil
                self.lastCommittedAt = commitTime
                self.isRerouting = false
                self.currentReason = nil
                self.activeTask = nil

                print("[RerouteManager] ✅ Reroute committed successfully at \(commitTime) — \(newRoute.formattedDistance), \(newRoute.steps.count) steps")
            } catch {
                // Distinguish cancellation from actual routing failure
                guard !Task.isCancelled,
                      !(error is CancellationError),
                      !((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled),
                      let s = self.navSession,
                      s.sessionGeneration == capturedSessionGen,
                      self.rerouteRequestGeneration == capturedRerouteGen else {
                    // Cancelled, obsolete session, or superseded request — NOT a failure!
                    return
                }

                self.isRerouting = false
                self.currentReason = nil
                self.activeTask = nil
                s.setRerouting(false)

                if reason == .offRoute {
                    self.failureCount += 1
                    let delayIndex = min(self.failureCount - 1, self.backoffDelays.count - 1)
                    let delay = self.backoffDelays[delayIndex]
                    let failureCompletionTime = self.now()
                    self.nextEligibleRerouteAt = failureCompletionTime.addingTimeInterval(delay)
                    print("[RerouteManager] ⚠️ Off-route reroute failed at \(failureCompletionTime) (attempt \(self.failureCount)). Next retry in \(delay)s at \(self.nextEligibleRerouteAt!)")
                } else {
                    print("[RerouteManager] ⚠️ Transport mode reroute failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Lifecycle Cancellation

    public func cancel() {
        invalidateActiveRequest()
        failureCount = 0
        nextEligibleRerouteAt = nil
        lastCommittedAt = nil
    }

    private func invalidateActiveRequest() {
        activeTask?.cancel()
        activeTask = nil
        rerouteRequestGeneration &+= 1
        isRerouting = false
        currentReason = nil
        navSession?.setRerouting(false)
    }
}
