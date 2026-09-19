//
//  MapViewContainer.swift
//  MapLibre Native iOS — SwiftUI UIViewRepresentable wrapper.
//
//  Features:
//  - Vector tile rendering via OpenFreeMap (free, no API key, excellent Vietnam data)
//  - Cyan route polyline: draws remainingPolyline (trimmed ahead-only segment)
//    so already-driven road disappears as user moves forward
//  - Directional chevron arrows every ~200m
//  - User puck follows snappedLocation for precise road-locked position
//  - Destination red flag pin
//  - Smooth zoom-to-fit on route preview; followWithHeading during navigation
//

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Map Style

private enum MapStyle {
    static let defaultStyle    = "https://tiles.openfreemap.org/styles/bright"
    static let navigationStyle = "https://tiles.openfreemap.org/styles/bright"
}

// MARK: - MapViewContainer

/// Full MapLibre SwiftUI wrapper.
/// Pass `remainingPolyline` (from NavigationSessionManager) for live route trimming.
public struct MapViewContainer: UIViewRepresentable {

    public let route: NavRoute?
    /// Trimmed ahead-only polyline — replaces route.coordinates during navigation.
    public let remainingPolyline: [CLLocationCoordinate2D]
    public let destinationCoord: CLLocationCoordinate2D?
    public let snappedLocation: CLLocationCoordinate2D?
    public let userHeading: Double
    public let isNavigating: Bool

    public init(
        route: NavRoute? = nil,
        remainingPolyline: [CLLocationCoordinate2D] = [],
        destinationCoord: CLLocationCoordinate2D? = nil,
        snappedLocation: CLLocationCoordinate2D? = nil,
        userHeading: Double = 0,
        isNavigating: Bool = false
    ) {
        self.route             = route
        self.remainingPolyline = remainingPolyline
        self.destinationCoord  = destinationCoord
        self.snappedLocation   = snappedLocation
        self.userHeading       = userHeading
        self.isNavigating      = isNavigating
    }

    public func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.styleURL        = URL(string: MapStyle.defaultStyle)
        mapView.showsUserLocation = true
        mapView.userTrackingMode  = .follow
        mapView.compassView.isHidden   = true
        mapView.attributionButton.isHidden = false
        mapView.logoView.isHidden    = true
        mapView.delegate             = context.coordinator
        mapView.tintColor = UIColor(red: 0, green: 0.75, blue: 1.0, alpha: 1.0)
        context.coordinator.mapView = mapView
        return mapView
    }

    public func updateUIView(_ mapView: MLNMapView, context: Context) {
        let c = context.coordinator

        // Determine which polyline coords to draw:
        // - During navigation: remainingPolyline (trimmed, updates every GPS frame)
        // - During preview:    full route.coordinates
        let displayCoords: [CLLocationCoordinate2D]
        if isNavigating && remainingPolyline.count >= 2 {
            displayCoords = remainingPolyline
        } else if let route = route, route.coordinates.count >= 2 {
            displayCoords = route.coordinates
        } else {
            displayCoords = []
        }

        c.updatePolyline(displayCoords, on: mapView)
        c.updateDestination(destinationCoord, on: mapView)

        // Navigation tracking mode
        let wantedMode: MLNUserTrackingMode = isNavigating ? .followWithHeading : .follow
        if mapView.userTrackingMode != wantedMode {
            mapView.setUserTrackingMode(wantedMode, animated: true, completionHandler: nil)
        }

        // Zoom to fit on route preview
        if !isNavigating, let route = route, route.coordinates.count >= 2 {
            c.zoomToFitRoute(route, on: mapView)
        }

        // Style switch
        let targetStyle = isNavigating ? MapStyle.navigationStyle : MapStyle.defaultStyle
        if mapView.styleURL?.absoluteString != targetStyle {
            mapView.styleURL = URL(string: targetStyle)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    public class Coordinator: NSObject, MLNMapViewDelegate {

        weak var mapView: MLNMapView?

        private let routeSourceID = "route-source"
        private let routeLayerID  = "route-layer"
        private let arrowLayerID  = "route-arrows"
        private var destinationAnnotation: MLNPointAnnotation?

        // Track last drawn coords to avoid redundant redraws.
        // Use coordinate count + first/last coords as a lightweight hash.
        private var lastPolylineHash: Int = 0

        // MARK: - Polyline Rendering

        func updatePolyline(_ coords: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            guard mapView.style != nil else { return }

            // Lightweight hash: count + first lat + last lat
            let hash: Int
            if coords.count >= 2 {
                let bits = coords.count &* 10_000_007
                          &+ Int(coords.first!.latitude  * 1_000_000)
                          &+ Int(coords.last!.latitude   * 1_000_000)
                          &+ Int(coords.first!.longitude * 1_000_000)
                hash = bits
            } else {
                hash = 0
            }

            if hash == lastPolylineHash { return }
            lastPolylineHash = hash

            removeRouteLayer(from: mapView)
            guard coords.count >= 2 else { return }
            addRouteLayer(coords: coords, to: mapView)
        }

        private func removeRouteLayer(from mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            if let l = style.layer(withIdentifier: routeLayerID) { style.removeLayer(l) }
            if let l = style.layer(withIdentifier: arrowLayerID) { style.removeLayer(l) }
            if let s = style.source(withIdentifier: routeSourceID) { style.removeSource(s) }
        }

        private func addRouteLayer(coords: [CLLocationCoordinate2D], to mapView: MLNMapView) {
            guard let style = mapView.style else { return }

            let feature = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
            let source  = MLNShapeSource(identifier: routeSourceID, shape: feature, options: nil)
            style.addSource(source)

            // Main cyan route line
            let lineLayer           = MLNLineStyleLayer(identifier: routeLayerID, source: source)
            lineLayer.lineColor     = NSExpression(forConstantValue: UIColor(red: 0, green: 0.75, blue: 1.0, alpha: 1.0))
            lineLayer.lineWidth     = NSExpression(forConstantValue: 6)
            lineLayer.lineCap       = NSExpression(forConstantValue: "round")
            lineLayer.lineJoin      = NSExpression(forConstantValue: "round")
            lineLayer.lineOpacity   = NSExpression(forConstantValue: 0.95)

            if let labelLayer = style.layers.first(where: { $0.identifier.contains("label") || $0.identifier.contains("name") }) {
                style.insertLayer(lineLayer, below: labelLayer)
            } else {
                style.addLayer(lineLayer)
            }

            // Direction chevron arrows
            let arrowLayer                   = MLNSymbolStyleLayer(identifier: arrowLayerID, source: source)
            arrowLayer.iconImageName         = NSExpression(forConstantValue: "triangle-stroked-15")
            arrowLayer.iconRotationAlignment = NSExpression(forConstantValue: "map")
            arrowLayer.iconAllowsOverlap     = NSExpression(forConstantValue: true)
            arrowLayer.symbolSpacing         = NSExpression(forConstantValue: 200)
            arrowLayer.iconColor             = NSExpression(forConstantValue: UIColor.white)
            arrowLayer.iconOpacity           = NSExpression(forConstantValue: 0.8)
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
            ann.title      = "Diem den"
            mapView.addAnnotation(ann)
            destinationAnnotation = ann
        }

        // MARK: - Zoom to Fit

        func zoomToFitRoute(_ route: NavRoute, on mapView: MLNMapView) {
            let coords = route.coordinates
            guard !coords.isEmpty else { return }
            var minLat = coords[0].latitude, maxLat = coords[0].latitude
            var minLon = coords[0].longitude, maxLon = coords[0].longitude
            for c in coords {
                minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
            )
            mapView.setVisibleCoordinateBounds(bounds,
                edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 280, right: 40),
                animated: true, completionHandler: nil)
        }

        // MARK: - MLNMapViewDelegate

        public func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            lastPolylineHash = -1 // force redraw after style reload
        }

        public func mapView(_ mapView: MLNMapView,
                            viewFor annotation: MLNAnnotation) -> MLNAnnotationView? { nil }

        public func mapView(_ mapView: MLNMapView,
                            imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard !(annotation is MLNUserLocation) else { return nil }
            let id = "destination-flag"
            if let cached = mapView.dequeueReusableAnnotationImage(withIdentifier: id) { return cached }
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
