import SwiftUI
import CoreLocation

#if canImport(MapLibre)
import MapLibre
#endif

/// Main SwiftUI Map Screen integrating MapLibre Native, Search Bar, Route Card, and Navigation HUD
public struct MainMapView: View {
    @StateObject private var viewModel = NavigationViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            // 1. Full-screen Vector Map
            MapLibreNativeRepresentable(
                route: viewModel.calculatedRoute,
                destination: viewModel.selectedDestination?.coordinate,
                userLocation: viewModel.navManager.userLocation?.coordinate,
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

// MARK: - MapLibre Native UIViewRepresentable
public struct MapLibreNativeRepresentable: UIViewRepresentable {
    public let route: NavRoute?
    public let destination: CLLocationCoordinate2D?
    public let userLocation: CLLocationCoordinate2D?
    public let isNavigating: Bool

    public func makeUIView(context: Context) -> UIView {
        #if canImport(MapLibre)
        let styleUrl = URL(string: "https://tiles.goong.io/assets/navigation_day.json?api_key=aBEuWpbGkXPXKEr7P5e5ghHBxcFzOd52P3NxXEhY")!
        let mapView = MLNMapView(frame: .zero, styleURL: styleUrl)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = true
        mapView.userTrackingMode = isNavigating ? .followWithCourse : .follow
        mapView.delegate = context.coordinator
        context.coordinator.mapView = mapView
        return mapView
        #else
        let fallbackView = UIView()
        fallbackView.backgroundColor = UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 1.0)
        return fallbackView
        #endif
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        #if canImport(MapLibre)
        guard uiView is MLNMapView else { return }
        context.coordinator.update(
            route: route,
            destination: destination,
            userLocation: userLocation,
            isNavigating: isNavigating
        )
        #endif
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    #if canImport(MapLibre)
    public class Coordinator: NSObject, MLNMapViewDelegate {
        weak var mapView: MLNMapView?
        private var polylineAnnotation: MLNPolyline?
        private var destinationAnnotation: MLNPointAnnotation?

        public func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            return UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
        }

        public func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            return 6.0
        }

        public func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            return 0.95
        }

        func update(route: NavRoute?, destination: CLLocationCoordinate2D?, userLocation: CLLocationCoordinate2D?, isNavigating: Bool) {
            guard let mapView = mapView else { return }

            // Update Polyline
            if let existing = polylineAnnotation {
                mapView.removeAnnotation(existing)
                polylineAnnotation = nil
            }

            if let route = route, route.coordinates.count >= 2 {
                var coords = route.coordinates
                let polyline = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                mapView.addAnnotation(polyline)
                self.polylineAnnotation = polyline

                if !isNavigating {
                    // Fit route bounds
                    mapView.setVisibleCoordinates(&coords, count: UInt(coords.count), edgePadding: UIEdgeInsets(top: 100, left: 40, bottom: 220, right: 40), animated: true)
                }
            }

            // Update Destination Pin
            if let existingPin = destinationAnnotation {
                mapView.removeAnnotation(existingPin)
                destinationAnnotation = nil
            }

            if let destCoord = destination {
                let pin = MLNPointAnnotation()
                pin.coordinate = destCoord
                pin.title = "Điểm đến"
                mapView.addAnnotation(pin)
                self.destinationAnnotation = pin
            }

            if isNavigating {
                mapView.userTrackingMode = .followWithHeading
            }
        }
    }
    #else
    public class Coordinator: NSObject {}
    #endif
}
