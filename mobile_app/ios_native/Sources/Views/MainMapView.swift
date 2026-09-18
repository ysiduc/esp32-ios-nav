import SwiftUI
import CoreLocation
import MapKit

/// Main SwiftUI Map Screen integrating MapLibre Native, Search Bar, Route Card, and Navigation HUD
public struct MainMapView: View {
    @StateObject private var viewModel = NavigationViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            // 1. Full-screen Vector Map
            MapKitRepresentable(
                route: viewModel.calculatedRoute,
                destination: viewModel.selectedDestination?.coordinate,
                snappedLocation: viewModel.navManager.snappedLocation,
                isNavigating: viewModel.navManager.isNavigating
            )
            .ignoresSafeArea()

            // 2. Active Driving Turn-by-Turn HUD Banner
            if viewModel.navManager.isNavigating {
                NavigationHUDView(
                    progress: viewModel.navManager.activeProgress,
                    bleState: viewModel.bleManager.connectionState,
                    onOpenBLE: { viewModel.showBLEScanner = true },
                    onStopNavigation: { viewModel.stopNavigation() }
                )
            } else {
                // 3. Browse / Search Mode Overlays
                VStack(spacing: 12) {
                    // Top Search Bar & BLE Quick Pill
                    HStack(spacing: 10) {
                        SearchBarView(
                            searchService: viewModel.searchService,
                            onSelect: { item in
                                viewModel.selectDestination(item)
                            },
                            onCancel: {
                                viewModel.searchService.clear()
                            }
                        )

                        // BLE Pill Button
                        Button(action: { viewModel.showBLEScanner = true }) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(viewModel.bleManager.connectionState == .connected ? .green : .white)
                                .frame(width: 44, height: 44)
                                .background(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.95))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)

                    // Transport Mode Selector Chips
                    if viewModel.selectedDestination != nil {
                        HStack(spacing: 10) {
                            transportModeChip(mode: "motorcycle", icon: "bicycle", title: "Xe máy")
                            transportModeChip(mode: "auto", icon: "car.fill", title: "Ô tô")
                            transportModeChip(mode: "bicycle", icon: "figure.walk", title: "Xe đạp/Bộ")
                        }
                        .padding(.horizontal, 14)
                    }

                    Spacer()

                    // Route Overview Bottom Card (When route is calculated)
                    if let route = viewModel.calculatedRoute, let destination = viewModel.selectedDestination {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(destination.name)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    Text(destination.formattedSubtitle)
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button(action: {
                                    viewModel.selectedDestination = nil
                                    viewModel.calculatedRoute = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.gray)
                                }
                            }

                            // Route Metrics (Time & Distance)
                            HStack(spacing: 20) {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.fill")
                                        .foregroundColor(.cyan)
                                    Text(route.formattedDuration)
                                        .font(.system(size: 22, weight: .black, design: .rounded))
                                        .foregroundColor(.cyan)
                                }

                                HStack(spacing: 6) {
                                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                        .foregroundColor(.gray)
                                    Text(route.formattedDistance)
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundColor(.white)
                                }

                                Spacer()
                            }

                            // Big Green "Start Navigation" Button
                            Button(action: {
                                viewModel.startNavigation()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "location.fill")
                                    Text("BẮT ĐẦU ĐIỀU HƯỚNG")
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.0, green: 0.55, blue: 0.27), Color(red: 0.0, green: 0.70, blue: 0.35)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(16)
                                .shadow(color: Color.green.opacity(0.4), radius: 8, x: 0, y: 4)
                            }
                        }
                        .padding(18)
                        .background(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.96))
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showBLEScanner) {
            BLEScannerSheet(bleManager: viewModel.bleManager)
        }
    }

    private func transportModeChip(mode: String, icon: String, title: String) -> some View {
        let isSelected = viewModel.transportMode == mode
        return Button(action: {
            viewModel.transportMode = mode
            if let dest = viewModel.selectedDestination {
                Task {
                    await viewModel.calculateRoute(to: dest.coordinate)
                }
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.cyan : Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.9))
            .foregroundColor(isSelected ? .black : .white)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

// MARK: - MapKit UIViewRepresentable
/// Native Apple Maps view — free, no API key, excellent Vietnam road data.
public struct MapKitRepresentable: UIViewRepresentable {
    public let route: NavRoute?
    public let destination: CLLocationCoordinate2D?
    public let snappedLocation: CLLocationCoordinate2D?
    public let isNavigating: Bool

    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.mapType = .standard
        mapView.delegate = context.coordinator
        mapView.userTrackingMode = .follow
        return mapView
    }

    public func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(
            mapView: mapView,
            route: route,
            destination: destination,
            snappedLocation: snappedLocation,
            isNavigating: isNavigating
        )
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator: NSObject, MKMapViewDelegate {
        private var routeOverlay: MKPolyline?
        private var destinationAnnotation: MKPointAnnotation?
        private var lastIsNavigating = false

        func update(
            mapView: MKMapView,
            route: NavRoute?,
            destination: CLLocationCoordinate2D?,
            snappedLocation: CLLocationCoordinate2D?,
            isNavigating: Bool
        ) {
            // --- Route polyline ---
            if let existing = routeOverlay {
                mapView.removeOverlay(existing)
                routeOverlay = nil
            }
            if let route = route, route.coordinates.count >= 2 {
                var coords = route.coordinates
                let polyline = MKPolyline(coordinates: &coords, count: coords.count)
                mapView.addOverlay(polyline, level: .aboveRoads)
                routeOverlay = polyline

                if !isNavigating {
                    // Fit map to route with padding
                    let rect = polyline.boundingMapRect
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 240, right: 40),
                        animated: true
                    )
                }
            }

            // --- Destination pin ---
            if let existing = destinationAnnotation {
                mapView.removeAnnotation(existing)
                destinationAnnotation = nil
            }
            if let destCoord = destination {
                let pin = MKPointAnnotation()
                pin.coordinate = destCoord
                pin.title = "Điểm đến"
                mapView.addAnnotation(pin)
                destinationAnnotation = pin
            }

            // --- Navigation tracking mode ---
            if isNavigating != lastIsNavigating {
                lastIsNavigating = isNavigating
                mapView.userTrackingMode = isNavigating ? .followWithHeading : .follow
            }
        }

        // Cyan route line
        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.0, green: 0.75, blue: 1.0, alpha: 1.0)
                renderer.lineWidth = 6.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // Red destination pin
        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let id = "destination"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            if let marker = view as? MKMarkerAnnotationView {
                marker.markerTintColor = UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
                marker.glyphImage = UIImage(systemName: "flag.checkered")
            }
            view.annotation = annotation
            return view
        }
    }
}
