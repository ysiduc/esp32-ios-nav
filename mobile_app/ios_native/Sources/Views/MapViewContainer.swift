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
    /// Authoritative preview render identity (e.g. selectedRouteCandidateID).
    public let routeRenderID: String?
    /// Trimmed ahead-only polyline — replaces route.coordinates during navigation.
    public let remainingPolyline: [CLLocationCoordinate2D]
    public let destinationCoord: CLLocationCoordinate2D?
    public let snappedLocation: CLLocationCoordinate2D?
    public let userHeading: Double
    public let isNavigating: Bool
    public let presentationMode: RouteMapPresentation?
    public let alternativeRoutes: [NavRoute]

    public init(
        route: NavRoute? = nil,
        routeRenderID: String? = nil,
        remainingPolyline: [CLLocationCoordinate2D] = [],
        destinationCoord: CLLocationCoordinate2D? = nil,
        snappedLocation: CLLocationCoordinate2D? = nil,
        userHeading: Double = 0,
        isNavigating: Bool = false,
        presentationMode: RouteMapPresentation? = nil,
        alternativeRoutes: [NavRoute] = []
    ) {
        self.route             = route
        self.routeRenderID     = routeRenderID
        self.remainingPolyline = remainingPolyline
        self.destinationCoord  = destinationCoord
        self.snappedLocation   = snappedLocation
        self.userHeading       = userHeading
        self.isNavigating      = isNavigating
        self.presentationMode  = presentationMode
        self.alternativeRoutes = alternativeRoutes
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

        // Determine which polyline coords to draw (P5.2.1 RouteMapPresentation):
        // - arrived: empty polyline (never redraw full historical route behind arrival overlay)
        // - navigating: remainingPolyline (trimmed, updates every GPS frame)
        // - preview: full route.coordinates
        // - none: empty
        let displayCoords: [CLLocationCoordinate2D]
        if let mode = presentationMode {
            switch mode {
            case .none, .arrived:
                displayCoords = []
            case .navigating:
                displayCoords = remainingPolyline.count >= 2 ? remainingPolyline : []
            case .preview:
                displayCoords = (route != nil && route!.coordinates.count >= 2) ? route!.coordinates : []
            }
        } else {
            if isNavigating && remainingPolyline.count >= 2 {
                displayCoords = remainingPolyline
            } else if let route = route, route.coordinates.count >= 2 {
                displayCoords = route.coordinates
            } else {
                displayCoords = []
            }
        }

        let effectiveIsNavigating = (presentationMode == .navigating) || (presentationMode == nil && isNavigating)
        c.isNavigating = effectiveIsNavigating
        c.userLocationView?.isHidden = effectiveIsNavigating
        c.updatePolyline(displayCoords, on: mapView)
        c.updateDestination(destinationCoord, on: mapView)
        c.updateMatchedPuck(snappedLocation, isNavigating: effectiveIsNavigating, on: mapView)

        // Navigation tracking mode
        let wantedMode: MLNUserTrackingMode = effectiveIsNavigating ? .followWithHeading : .follow
        if mapView.userTrackingMode != wantedMode {
            mapView.setUserTrackingMode(wantedMode, animated: true, completionHandler: nil)
        }

        // Zoom to fit on route preview (cached to avoid animating every SwiftUI frame)
        let isPreview = (presentationMode == .preview) || (presentationMode == nil && !isNavigating)
        if isPreview, let route = route, route.coordinates.count >= 2 {
            let shouldZoom: Bool
            if let renderID = routeRenderID, !renderID.isEmpty {
                shouldZoom = c.renderPolicy.shouldZoomToFit(routeIdentifier: renderID)
            } else {
                shouldZoom = c.renderPolicy.shouldZoomToFit(routeCoordinates: route.coordinates)
            }
            if shouldZoom {
                c.renderPolicy.recordPreviewZoom()
                c.zoomToFitRoute(route, on: mapView)
            }
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
        private let navigationPositionSourceID = "navigation-position-source"
        private let navigationPositionLayerID  = "navigation-position-layer"

        var isNavigating: Bool = false
        var userLocationView: MLNUserLocationAnnotationView?
        private var destinationAnnotation: MLNPointAnnotation?
        private var lastDestinationCoord: CLLocationCoordinate2D?

        public let renderPolicy = MapRenderPolicy()

        // MARK: - Polyline Rendering

        func updatePolyline(_ coords: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            guard let style = mapView.style else { return }

            let sourceExists = (style.source(withIdentifier: routeSourceID) != nil)
            let layerExists = (style.layer(withIdentifier: routeLayerID) != nil)

            let action = renderPolicy.evaluatePolylineUpdate(
                coordsCount: coords.count,
                sourceExists: sourceExists,
                layerExists: layerExists
            )

            switch action {
            case .updateShapeInPlace:
                if let source = style.source(withIdentifier: routeSourceID) as? MLNShapeSource {
                    let feature = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
                    source.shape = feature
                    renderPolicy.recordShapeUpdate()
                }
            case .initialBuild, .rebuildForMissingLayer:
                removeRouteLayer(from: mapView)
                addRouteLayer(coords: coords, to: mapView)
                renderPolicy.recordLayerRebuild()
            case .clearShape:
                if let source = style.source(withIdentifier: routeSourceID) as? MLNShapeSource {
                    source.shape = nil
                }
            case .noChange:
                break
            }
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

        // MARK: - Alternative Preview Routes (P5.3)

        private let altRouteSourceID = "route-alternatives-source"
        private let altRouteLayerID  = "route-alternatives-layer"

        func updateAlternativePolylines(_ routes: [NavRoute], isPreview: Bool, on mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            guard isPreview && !routes.isEmpty else {
                removeAlternativeRouteLayers(from: mapView)
                return
            }

            var features: [MLNPolylineFeature] = []
            for r in routes {
                guard r.coordinates.count >= 2 else { continue }
                features.append(MLNPolylineFeature(coordinates: r.coordinates, count: UInt(r.coordinates.count)))
            }

            guard !features.isEmpty else {
                removeAlternativeRouteLayers(from: mapView)
                return
            }

            let multiFeature = MLNMultiPolylineFeature(polylines: features)

            if let source = style.source(withIdentifier: altRouteSourceID) as? MLNShapeSource {
                source.shape = multiFeature
            } else {
                let source = MLNShapeSource(identifier: altRouteSourceID, shape: multiFeature, options: nil)
                style.addSource(source)

                let lineLayer = MLNLineStyleLayer(identifier: altRouteLayerID, source: source)
                lineLayer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.45, green: 0.52, blue: 0.62, alpha: 0.65))
                lineLayer.lineWidth = NSExpression(forConstantValue: 4.5)
                lineLayer.lineCap = NSExpression(forConstantValue: "round")
                lineLayer.lineJoin = NSExpression(forConstantValue: "round")

                if let mainRouteLayer = style.layer(withIdentifier: routeLayerID) {
                    style.insertLayer(lineLayer, below: mainRouteLayer)
                } else if let labelLayer = style.layers.first(where: { $0.identifier.contains("label") }) {
                    style.insertLayer(lineLayer, below: labelLayer)
                } else {
                    style.addLayer(lineLayer)
                }
            }
        }

        private func removeAlternativeRouteLayers(from mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            if let l = style.layer(withIdentifier: altRouteLayerID) { style.removeLayer(l) }
            if let s = style.source(withIdentifier: altRouteSourceID) { style.removeSource(s) }
        }

        // MARK: - Matched Navigation Puck

        func updateMatchedPuck(_ coord: CLLocationCoordinate2D?, isNavigating: Bool, on mapView: MLNMapView) {
            guard let style = mapView.style else { return }

            guard isNavigating, let coord = coord else {
                // Clean up matched navigation puck when not actively navigating
                if let layer = style.layer(withIdentifier: navigationPositionLayerID) {
                    style.removeLayer(layer)
                }
                if let source = style.source(withIdentifier: navigationPositionSourceID) {
                    style.removeSource(source)
                }
                return
            }

            let feature = MLNPointFeature()
            feature.coordinate = coord

            if let source = style.source(withIdentifier: navigationPositionSourceID) as? MLNShapeSource {
                source.shape = feature
            } else {
                let source = MLNShapeSource(identifier: navigationPositionSourceID, shape: feature, options: nil)
                style.addSource(source)

                let layer = MLNCircleStyleLayer(identifier: navigationPositionLayerID, source: source)
                layer.circleColor = NSExpression(forConstantValue: UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0))
                layer.circleRadius = NSExpression(forConstantValue: 9)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: 3)
                layer.circleOpacity = NSExpression(forConstantValue: 1.0)
                style.addLayer(layer)
            }
        }

        // MARK: - Destination Annotation

        func updateDestination(_ coord: CLLocationCoordinate2D?, on mapView: MLNMapView) {
            // Avoid recreating annotation if destination coordinate has not changed
            let isSame: Bool
            switch (lastDestinationCoord, coord) {
            case (.none, .none):
                isSame = true
            case let (.some(c1), .some(c2)):
                isSame = abs(c1.latitude - c2.latitude) < 0.000001 &&
                         abs(c1.longitude - c2.longitude) < 0.000001
            default:
                isSame = false
            }

            if isSame && (destinationAnnotation != nil || coord == nil) {
                return
            }

            if let existing = destinationAnnotation {
                mapView.removeAnnotation(existing)
                destinationAnnotation = nil
            }
            lastDestinationCoord = coord

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
            renderPolicy.reset() // force rebuild after style reload
        }

        public func mapView(_ mapView: MLNMapView,
                            viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is MLNUserLocation {
                let view = userLocationView ?? MLNUserLocationAnnotationView(frame: .zero)
                userLocationView = view
                view.isHidden = isNavigating
                return view
            }
            return nil
        }

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
