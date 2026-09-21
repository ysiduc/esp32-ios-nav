//
//  MapRenderPolicy.swift
//  Pure rendering policy and metrics tracking for MapLibre route layers:
//  in-place shape updates vs layer rebuilds, and camera zoom-to-fit caching.
//

import CoreLocation
import Foundation

public enum MapRenderAction: Equatable, Sendable {
    case initialBuild
    case updateShapeInPlace
    case rebuildForMissingLayer
    case clearShape
    case noChange
}

/// Pure policy and counter engine for map rendering operations.
public final class MapRenderPolicy: @unchecked Sendable {

    public private(set) var routeShapeUpdates: Int = 0
    public private(set) var routeLayerRebuilds: Int = 0
    public private(set) var previewZooms: Int = 0

    private var lastRenderedCoordinatesCount: Int = 0
    private var lastZoomedRouteSignature: String?

    public init() {}

    public func reset() {
        routeShapeUpdates = 0
        routeLayerRebuilds = 0
        previewZooms = 0
        lastRenderedCoordinatesCount = 0
        lastZoomedRouteSignature = nil
    }

    /// Evaluates the render action for a polyline update given source/layer availability.
    public func evaluatePolylineUpdate(
        coordsCount: Int,
        sourceExists: Bool,
        layerExists: Bool
    ) -> MapRenderAction {
        guard coordsCount >= 2 else {
            return .clearShape
        }

        if sourceExists && layerExists {
            return .updateShapeInPlace
        } else if !sourceExists {
            return .initialBuild
        } else {
            return .rebuildForMissingLayer
        }
    }

    public func recordShapeUpdate() {
        routeShapeUpdates += 1
    }

    public func recordLayerRebuild() {
        routeLayerRebuilds += 1
    }

    public func recordPreviewZoom() {
        previewZooms += 1
    }

    /// Determines if zoomToFitRoute should be invoked for route preview.
    /// Returns true only when a new distinct preview route is presented.
    ///
    /// - Parameter routeIdentifier: An authoritative render identity supplied by the caller.
    ///   Should incorporate the route generation or candidate ID so that alternative routes
    ///   sharing the same endpoints (but different geometry) are not incorrectly deduplicated.
    ///   Example: "\(candidateID)-\(activeRouteGeneration)" or a UUID.
    public func shouldZoomToFit(routeIdentifier: String) -> Bool {
        guard !routeIdentifier.isEmpty else { return false }
        if routeIdentifier == lastZoomedRouteSignature { return false }
        lastZoomedRouteSignature = routeIdentifier
        return true
    }

    /// Legacy coordinate-hash overload. Prefer `shouldZoomToFit(routeIdentifier:)` when the
    /// caller has an authoritative route identity (candidate ID + generation counter).
    /// This version is susceptible to false-negative deduplication for alternative routes
    /// that share the same endpoints and coordinate count but differ in midpoints.
    public func shouldZoomToFit(routeCoordinates: [CLLocationCoordinate2D]) -> Bool {
        guard routeCoordinates.count >= 2 else { return false }
        let first = routeCoordinates.first!
        let last  = routeCoordinates.last!
        let mid   = routeCoordinates[routeCoordinates.count / 2]
        // Include midpoint to distinguish alternative routes with shared endpoints
        let sig = "\(routeCoordinates.count)_\(Int(first.latitude * 1e5))_\(Int(first.longitude * 1e5))_\(Int(mid.latitude * 1e5))_\(Int(mid.longitude * 1e5))_\(Int(last.latitude * 1e5))_\(Int(last.longitude * 1e5))"
        return shouldZoomToFit(routeIdentifier: sig)
    }

    public func invalidatePreviewZoomCache() {
        lastZoomedRouteSignature = nil
    }
}
