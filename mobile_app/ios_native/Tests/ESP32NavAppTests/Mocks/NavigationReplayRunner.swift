//
//  NavigationReplayRunner.swift
//  Test harness for driving NavigationSessionManager with deterministic timestamped samples.
//

import CoreLocation
import Foundation
@testable import ESP32NavApp

@MainActor
public final class NavigationReplayRunner {

    public let sessionManager: NavigationSessionManager

    public private(set) var recordedProgress: [NavigationProgress] = []
    public private(set) var recordedOffRouteDecisions: [(decision: OffRouteDecision, location: CLLocation)] = []
    public private(set) var arrivalCount: Int = 0

    public var capturedProgress: [NavigationProgress] { recordedProgress }

    public init(sessionManager: NavigationSessionManager) {
        self.sessionManager = sessionManager
        setupCallbacks()
    }

    public init() {
        self.sessionManager = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        setupCallbacks()
    }

    private func setupCallbacks() {
        sessionManager.onProgressUpdate = { [weak self] progress in
            self?.recordedProgress.append(progress)
        }
        sessionManager.onOffRouteDecision = { [weak self] decision, location in
            self?.recordedOffRouteDecisions.append((decision, location))
        }
        sessionManager.onArrived = { [weak self] in
            self?.arrivalCount += 1
        }
    }

    /// Helper to install and start navigation on a route
    public func installRoute(_ route: NavRoute, destination: NavigationDestination? = nil) {
        let dest = destination ?? NavigationDestination(
            coordinate: route.coordinates.last ?? CLLocationCoordinate2D(),
            name: "Destination"
        )
        sessionManager.startNavigation(route: route, destination: dest)
    }

    /// Feeds a sequence of replay samples into the session manager synchronously.
    public func replay(samples: [NavigationReplaySample]) {
        for sample in samples {
            sessionManager.ingestLocation(sample.toCLLocation())
        }
    }

    /// Reset recorded events between runs.
    public func resetRecordedEvents() {
        recordedProgress.removeAll()
        recordedOffRouteDecisions.removeAll()
        arrivalCount = 0
    }
}
