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

    // BLE transmission metrics
    public var blePacketsGenerated: Int = 0
    public var bleWritesPerformed: Int = 0
    public var bleDuplicatesSuppressed: Int = 0
    public var blePacketsCoalesced: Int = 0

    // Map rendering metrics
    public var mapRouteShapeUpdates: Int = 0
    public var mapRouteLayerRebuilds: Int = 0
    public var mapPreviewZooms: Int = 0

    public init() {}

    public mutating func reset() {
        self = NavigationDiagnostics()
    }
}
