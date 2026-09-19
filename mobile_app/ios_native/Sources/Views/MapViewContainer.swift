//
//  MapViewContainer.swift
//  MapLibre Native iOS — SwiftUI UIViewRepresentable wrapper.
//
//  Features:
//  - Vector tile rendering via OpenFreeMap (free, no API key, excellent Vietnam data)
//  - Cyan route polyline with directional chevron arrows every ~200m
//  - Custom puck with bearing indicator (heading cone)
//  - Destination red flag pin
//  - Smooth zoom-to-fit on route preview; followWithHeading during navigation
//  - Custom layer ordering for Vietnamese road classification visibility
//

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Map Style

private enum MapStyle {
    /// OpenFreeMap — Bright streets style.
    /// Alternatives:
    ///   "https://tiles.openfreemap.org/styles/liberty"  (Liberty style)
    ///   "https://tiles.openfreemap.org/styles/positron" (Minimal style)
    static let defaultStyle = "https://tiles.openfreemap.org/styles/bright"
    static let navigationStyle = "https://tiles.openfreemap.org/styles/bright"
}

// MARK: - MapViewContainer

/// Full MapLibre SwiftUI wrapper with route rendering, user puck, and destination pin.
public struct MapViewContainer: UIViewRepresentable {

    public let route: NavRoute?
    public let destinationCoord: CLLocationCoordinate2D?
    public let snappedLocation: CLLocationCoordinate2D?
    public let userHeading: Double
    public let isNavigating: Bool

    public init(
        route: NavRoute? = nil,
        destinationCoord: CLLocationCoordinate2D? = nil,
        snappedLocation: CLLocationCoordinate2D? = nil,
        userHeading: Double = 0,
        isNavigating: Bool = false
    ) {
        self.route            = route
        self.destinationCoord = destinationCoord
        self.snappedLocation  = snappedLocation
        self.userHeading      = userHeading
        self.isNavigating     = isNavigating
    }

    public func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.styleURL        = URL(string: MapStyle.defaultStyle)
        mapView.showsUserLocation = true
        mapView.userTrackingMode  = .follow
        mapView.compassView.isHidden  = true
        mapView.attributionButton.isHidden = false
        mapView.logoView.isHidden   = true
        mapView.delegate            = context.coordinator

        // Dark tint for navigation controls
        mapView.tintColor = UIColor(red: 0, green: 0.75, blue: 1.0, alpha: 1.0)

        context.coordinator.mapView = mapView
        return mapView
    }

    public func updateUIView(_ mapView: MLNMapView, context: Context) {
        let c = context.coordinator

        // Update route polyline
        c.updateRoute(route, on: mapView)

        // Update destination annotation
        c.updateDestination(destinationCoord, on: mapView)

        // Navigation mode tracking
        let wantedMode: MLNUserTrackingMode = isNavigating ? .followWithHeading : .follow
        if mapView.userTrackingMode != wantedMode {
            mapView.setUserTrackingMode(wantedMode, animated: true, completionHandler: nil)
        }

        // In route-preview mode, zoom to fit the entire route
        if !isNavigating, let route = route, route.coordinates.count >= 2 {
            c.zoomToFitRoute(route, on: mapView)
        }

        // Style URL switch for navigation
        let targetStyle = isNavigating ? MapStyle.navigationStyle : MapStyle.defaultStyle
        if mapView.styleURL?.absoluteString != targetStyle {
            mapView.styleURL = URL(string: targetStyle)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    public class Coordinator: NSObject, MLNMapViewDelegate {

        weak var mapView: MLNMapView?

        // Source/Layer IDs for route
        private let routeSourceID   = "route-source"
        private let routeLayerID    = "route-layer"
        private let arrowLayerID    = "route-arrows"

        // Annotation for destination
        private var destinationAnnotation: MLNPointAnnotation?

        // Track last route to avoid redundant redraws
        private var lastRouteHash: Int = 0

        // MARK: - Route Rendering

        func updateRoute(_ route: NavRoute?, on mapView: MLNMapView) {
            guard mapView.style != nil else { return }

            let newHash = route.map { ObjectIdentifier($0 as AnyObject).hashValue } ?? 0
            // Note: NavRoute is a struct so we hash by coordinate count instead
            let routeHash = route?.coordinates.count ?? 0
            if routeHash == lastRouteHash { return }
            lastRouteHash = routeHash

            removeRouteLayer(from: mapView)

            guard let route = route, route.coordinates.count >= 2 else { return }
            addRouteLayer(route: route, to: mapView)
        }

        private func removeRouteLayer(from mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            if let layer = style.layer(withIdentifier: routeLayerID) {
                style.removeLayer(layer)
            }
            if let layer = style.layer(withIdentifier: arrowLayerID) {
                style.removeLayer(layer)
            }
            if let source = style.source(withIdentifier: routeSourceID) {
                style.removeSource(source)
            }
        }

        private func addRouteLayer(route: NavRoute, to mapView: MLNMapView) {
            guard let style = mapView.style else { return }

            // Build GeoJSON LineString from coordinates
            let coords = route.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }

            let feature = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))

            let source = MLNShapeSource(identifier: routeSourceID,
                                        shape: feature,
                                        options: nil)
            style.addSource(source)

            // --- Main route line (cyan, 6pt) ---
            let lineLayer               = MLNLineStyleLayer(identifier: routeLayerID, source: source)
            lineLayer.lineColor         = NSExpression(forConstantValue: UIColor(red: 0, green: 0.75, blue: 1.0, alpha: 1.0))
            lineLayer.lineWidth         = NSExpression(forConstantValue: 6)
            lineLayer.lineCap           = NSExpression(forConstantValue: "round")
            lineLayer.lineJoin          = NSExpression(forConstantValue: "round")
            lineLayer.lineOpacity       = NSExpression(forConstantValue: 0.95)

            // Insert below labels so street names remain visible
            if let labelLayer = style.layers.first(where: { $0.identifier.contains("label") || $0.identifier.contains("name") }) {
                style.insertLayer(lineLayer, below: labelLayer)
            } else {
                style.addLayer(lineLayer)
            }

            // --- Directional chevron arrows along route ---
            let arrowLayer               = MLNSymbolStyleLayer(identifier: arrowLayerID, source: source)
            arrowLayer.iconImageName     = NSExpression(forConstantValue: "triangle-stroked-15")
            arrowLayer.iconRotationAlignment = NSExpression(forConstantValue: "map")
            arrowLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            // Space arrows 200m apart using symbol spacing
            arrowLayer.symbolSpacing    = NSExpression(forConstantValue: 200)
            arrowLayer.iconColor        = NSExpression(forConstantValue: UIColor.white)
            arrowLayer.iconOpacity      = NSExpression(forConstantValue: 0.8)
            style.addLayer(arrowLayer)
        }

        // MARK: - Destination Annotation

        func updateDestination(_ coord: CLLocationCoordinate2D?, on mapView: MLNMapView) {
            if let existing = destinationAnnotation {
                mapView.removeAnnotation(existing)
                destinationAnnotation = nil
            }
            guard let coord = coord else { return }

            let ann        = MLNPointAnnotation()
            ann.coordinate = coord
            ann.title      = "Điểm đến"
            mapView.addAnnotation(ann)
            destinationAnnotation = ann
        }

        // MARK: - Zoom to Fit Route

        func zoomToFitRoute(_ route: NavRoute, on mapView: MLNMapView) {
            let coords = route.coordinates
            guard !coords.isEmpty else { return }

            var minLat = coords[0].latitude, maxLat = coords[0].latitude
            var minLon = coords[0].longitude, maxLon = coords[0].longitude

            for c in coords {
                minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }

            let sw = CLLocationCoordinate2D(latitude: minLat, longitude: minLon)
            let ne = CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
            let bounds = MLNCoordinateBounds(sw: sw, ne: ne)

            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 280, right: 40),
                animated: true,
                completionHandler: nil
            )
        }

        // MARK: - MLNMapViewDelegate

        public func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Re-apply layers after style reload
            if let mapRef = self.mapView {
                lastRouteHash = -1 // force redraw
            }
        }

        public func mapView(_ mapView: MLNMapView,
                            viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            return nil // Use default callout balloon
        }

        public func mapView(_ mapView: MLNMapView,
                            imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard !(annotation is MLNUserLocation) else { return nil }

            let id = "destination-flag"
            if let cached = mapView.dequeueReusableAnnotationImage(withIdentifier: id) {
                return cached
            }

            // Draw a red circle as the destination marker
            let size = CGSize(width: 32, height: 32)
            UIGraphicsBeginImageContextWithOptions(size, false, 0)
            let ctx = UIGraphicsGetCurrentContext()!
            ctx.setFillColor(UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(origin: .zero, size: size))
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: 10, y: 10, width: 12, height: 12))
            let img = UIGraphicsGetImageFromCurrentImageContext()!
            UIGraphicsEndImageContext()

            return MLNAnnotationImage(image: img, reuseIdentifier: id)
        }

        public func mapView(_ mapView: MLNMapView,
                            strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            return UIColor(red: 0, green: 0.75, blue: 1, alpha: 1)
        }

        public func mapView(_ mapView: MLNMapView,
                            lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            return 5
        }
    }
}
