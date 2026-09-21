//
//  NavigationDiagnostics.swift
//  Lightweight, thread-safe runtime diagnostics counters for debugging and test verification.
//

import Foundation

/// Snapshot of runtime navigation, BLE, and rendering metrics.
public struct NavigationDiagnostics: Sendable, Equatable {
    // Location metrics
    public var locationsReceived: Int = 0
    public var locationsAccepted: Int = 0
    public var locationsRejectedForAccuracy: Int = 0
    public var progressComputations: Int = 0

    // Off-route & reroute metrics
    public var offRouteObservations: Int = 0
    public var offRouteConfirmations: Int = 0
    public var rerouteRequests: Int = 0
    public var rerouteCommits: Int = 0

    // BLE transmission metrics are owned by BLESendScheduler
    // (packetsGenerated, writesPerformed, duplicatesSuppressed, packetsCoalesced).
    // Read them directly from BLEManager.scheduler for accurate values.

    // Map rendering metrics are owned by MapRenderPolicy
    // (routeShapeUpdates, routeLayerRebuilds, previewZooms).
    // Read them directly from the MapRenderPolicy instance for accurate values.

    public init() {}

    public mutating func reset() {
        self = NavigationDiagnostics()
    }
}
