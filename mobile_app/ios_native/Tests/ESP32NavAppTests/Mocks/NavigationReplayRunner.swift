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

    public init(sessionManager: NavigationSessionManager = NavigationSessionManager(requestLocationAuthorizationOnInit: false)) {
        self.sessionManager = sessionManager
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
