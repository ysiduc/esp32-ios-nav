//
//  MainMapView.swift
//  Primary SwiftUI screen — search, route preview, and active navigation HUD.
//
//  Screen Layers (bottom → top):
//    1. MapViewContainer (MapLibre fullscreen)
//    2. Search bar + autocomplete list overlay (top of screen)
//    3. Route preview bottom sheet (when state == .routePreview)
//    4. Navigation HUD (when state == .navigating)
//    5. BLE scanner sheet (modal)
//    6. Arrived overlay (when state == .arrived)
//

import CoreLocation
import MapLibre
import SwiftUI

public struct MainMapView: View {

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = NavigationViewModel()

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {

            // ── Layer 1: Full-screen Map ──────────────────────────────────
            let presentation: RouteMapPresentation = {
                switch viewModel.navSession.state {
                case .navigating: return .navigating
                case .routePreview: return .preview
                case .arrived: return .arrived
                case .idle, .searching: return .none
                }
            }()

            let altRoutes = viewModel.routeCandidates
                .filter { bash.id != viewModel.selectedRouteCandidateID }
                .map(\.route)

            MapViewContainer(
                route: viewModel.activeRoute,
                routeRenderID: viewModel.selectedRouteCandidateID,
                remainingPolyline: viewModel.navSession.remainingPolyline,
                destinationCoord: viewModel.selectedDestination?.coordinate,
                snappedLocation: viewModel.snappedLocation,
                userHeading: viewModel.heading,
                isNavigating: viewModel.isNavigating,
                presentationMode: presentation,
                alternativeRoutes: altRoutes
            )
            .edgesIgnoringSafeArea(.all)

            // ── Layer 2: Search UI (hidden during navigation) ─────────────
            if !viewModel.isNavigating && viewModel.navSession.state != .arrived {
                searchLayer
            }

            // ── Layer 3: Route Preview Bottom Sheet ───────────────────────
            if viewModel.navSession.state == .routePreview {
                VStack {
                    Spacer()
                    routePreviewSheet
                }
                .edgesIgnoringSafeArea(.bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // ── Layer 4: Active Navigation HUD ────────────────────────────
            if viewModel.isNavigating {
                NavigationHUDView(
                    progress: viewModel.progress,
                    bleState: viewModel.bleManager.connectionState,
                    isRerouting: viewModel.isRerouting,
                    onOpenBLE: { viewModel.showBLEScanner = true },
                    onStopNavigation: { viewModel.stopNavigation() }
                )
                .transition(.opacity)

                #if DEBUG
                if let trace = viewModel.navSession.diagnostics.latestFieldTrace {
                    debugOverlay(trace: trace)
                        .padding(.top, 100)
                        .padding(.leading, 14)
                }
                #endif
            }

            // ── Layer 5: Arrived Overlay ──────────────────────────────────
            if viewModel.navSession.state == .arrived {
                arrivedOverlay
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.navSession.state)
        .sheet(isPresented: $viewModel.showBLEScanner) {
            BLEScannerSheet(bleManager: viewModel.bleManager)
        }
        .onChange(of: scenePhase) { newPhase in
            viewModel.handleScenePhase(newPhase)
        }
    }

    // MARK: - Search Layer

    private var searchLayer: some View {
        VStack(spacing: 0) {
            // Top controls bar
            HStack(spacing: 10) {
                // Search bar
                searchBar

                // BLE status button
                Button(action: { viewModel.showBLEScanner = true }) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.95))
                            .frame(width: 44, height: 44)
                            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(
                                viewModel.bleManager.connectionState == .connected
                                    ? .green : .white.opacity(0.7)
                            )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            // Autocomplete suggestion list
            if viewModel.isSearchActive && !viewModel.searchService.predictions.isEmpty {
                autocompleteList
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            // Empty-results feedback
            if viewModel.isSearchActive
                && viewModel.searchQuery.count >= 2
                && !viewModel.searchService.isLoading
                && viewModel.searchService.predictions.isEmpty
                && viewModel.searchService.errorMessage == nil {
                Text("Không tìm thấy địa điểm phù hợp")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }

            // Search error banner
            if viewModel.isSearchActive, let err = viewModel.searchService.errorMessage {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }

            // Place Detail / Route error banner
            if let routeErr = viewModel.routeErrorMessage {
                Text(routeErr)
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }

            // Transport mode chips (visible when a destination is selected)
            if viewModel.navSession.state == .idle || viewModel.navSession.state == .searching {
                if viewModel.selectedDestination != nil || viewModel.isCalculatingRoute {
                    transportChips
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }
            }

            Spacer()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(
                    viewModel.isSearchActive
                        ? Color(red: 0, green: 0.75, blue: 1.0)
                        : .gray
                )
                .font(.system(size: 17, weight: .medium))
                .animation(.easeInOut(duration: 0.2), value: viewModel.isSearchActive)

            TextField("Tìm kiếm địa điểm…", text: Binding(
                get: { viewModel.searchQuery },
                set: { viewModel.updateSearchQuery($0) }
            ))
            .font(.system(size: 15))
            .foregroundColor(.white)
            .accentColor(Color(red: 0, green: 0.75, blue: 1.0))
            .onTapGesture { viewModel.beginSearch() }

            if viewModel.isSearchActive || viewModel.selectedPrediction != nil {
                Button(action: { viewModel.clearSearch() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.system(size: 16))
                }
            }

            if viewModel.searchService.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.cyan)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            viewModel.isSearchActive
                                ? Color(red: 0, green: 0.75, blue: 1.0).opacity(0.6)
                                : Color.white.opacity(0.08),
                            lineWidth: 1.5
                        )
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isSearchActive)
    }

    // MARK: - Autocomplete List

    private var autocompleteList: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.searchService.predictions) { prediction in
                Button(action: { viewModel.selectPrediction(prediction) }) {
                    HStack(spacing: 12) {
                        // Place type icon
                        Image(systemName: placeIcon(for: prediction))
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0, green: 0.75, blue: 1.0))
                            .frame(width: 28, height: 28)
                            .background(Color(red: 0, green: 0.75, blue: 1.0).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(prediction.mainText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            if !prediction.secondaryText.isEmpty {
                                Text(prediction.secondaryText)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if prediction.id != viewModel.searchService.predictions.last?.id {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.13, blue: 0.19).opacity(0.98))
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Transport Mode Chips

    private var transportChips: some View {
        HStack(spacing: 8) {
            transportChip(mode: "motorcycle", icon: "motorcycle", title: "Xe máy")
            transportChip(mode: "auto",       icon: "car.fill",    title: "Ô tô")
            transportChip(mode: "bicycle",    icon: "bicycle",     title: "Xe đạp")
            transportChip(mode: "pedestrian", icon: "figure.walk", title: "Đi bộ")
        }
    }

    private func transportChip(mode: String, icon: String, title: String) -> some View {
        let isSelected = viewModel.transportMode == mode
        return Button(action: {
            viewModel.transportMode = mode
            viewModel.recalculateForTransportMode()
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color(red: 0, green: 0.75, blue: 1.0)
                    : Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.93)
            )
            .foregroundColor(isSelected ? .black : .white)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? Color(red: 0, green: 0.75, blue: 1.0)
                            : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isSelected
                    ? Color(red: 0, green: 0.75, blue: 1.0).opacity(0.35)
                    : .clear,
                radius: 5, x: 0, y: 2
            )
        }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - Route Preview Bottom Sheet

    private var routePreviewSheet: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.25))
                .frame(width: 40, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if viewModel.isCalculatingRoute {
                HStack(spacing: 12) {
                    ProgressView().tint(.cyan)
                    Text("Đang tính đường…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 20)
            } else if let route = viewModel.activeRoute {
                routeDetails(route: route)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.10, green: 0.13, blue: 0.19).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: -5)
        .padding(.horizontal, 8)
        .padding(.bottom, 0)
    }

    private func routeDetails(route: NavRoute) -> some View {
        VStack(spacing: 0) {
            // Destination name
            if let dest = viewModel.selectedDestination {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 18))
                    Text(dest.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            // Route stats row
            HStack(spacing: 20) {
                // ETA
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.formattedDuration)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                    Text("Thời gian dự kiến")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }

                Divider()
                    .frame(height: 36)
                    .background(Color.white.opacity(0.15))

                // Distance
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.formattedDistance)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Khoảng cách")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }

                Divider()
                    .frame(height: 36)
                    .background(Color.white.opacity(0.15))

                // Steps count
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(route.steps.count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Chỉ dẫn")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Alternative route choices (P4)
            if viewModel.routeCandidates.count > 1 {
                alternativeRouteChips
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            // Degraded fallback banner if applicable (P4)
            if viewModel.isDegradedRoute {
                degradedWarningBanner
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            // Transport chips row
            transportChips
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            // Start Navigation CTA
            Button(action: { viewModel.startNavigation() }) {
                HStack(spacing: 10) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("BẮT ĐẦU ĐIỀU HƯỚNG")
                        .font(.system(size: 15, weight: .black))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0, green: 0.85, blue: 0.42),
                            Color(red: 0, green: 0.70, blue: 0.35)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(18)
                .shadow(
                    color: Color(red: 0, green: 0.7, blue: 0.35).opacity(0.45),
                    radius: 10, x: 0, y: 5
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Arrived Overlay

    private var arrivedOverlay: some View {
        VStack {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "flag.checkered.2.crossed")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))

                Text("Đã đến nơi!")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                if let dest = viewModel.selectedDestination {
                    Text(dest.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }

                Button(action: { viewModel.stopNavigation() }) {
                    Text("Đóng")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.2, green: 0.9, blue: 0.5))
                        .cornerRadius(14)
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color(red: 0.10, green: 0.13, blue: 0.19).opacity(0.98))
                    .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: -5)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Alternative Route Choices (P4)

    private var alternativeRouteChips: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.routeCandidates) { candidate in
                let isSelected = (candidate.id == viewModel.selectedRouteCandidateID)
                Button(action: {
                    viewModel.selectRouteCandidate(id: candidate.id)
                }) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(candidate.label)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(isSelected ? .black : .white)
                            if candidate.isPrimary {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(isSelected ? .black : .yellow)
                            }
                        }

                        Text(candidate.route.formattedDuration)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(isSelected ? .black : Color(red: 0.2, green: 0.9, blue: 0.5))

                        Text(candidate.route.formattedDistance)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? Color.black.opacity(0.7) : .gray)

                        if let delta = candidate.formattedDelta {
                            Text(delta)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(isSelected ? Color.black.opacity(0.85) : Color.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        isSelected
                            ? Color(red: 0, green: 0.85, blue: 0.42)
                            : Color.white.opacity(0.08)
                    )
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected
                                    ? Color(red: 0, green: 0.95, blue: 0.5)
                                    : Color.white.opacity(0.15),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var degradedWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 13))
            Text(viewModel.degradedReason ?? "Lộ trình ô tô tạm thời (MapKit fallback)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.yellow)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func placeIcon(for prediction: SearchPrediction) -> String {
        let desc = prediction.description.lowercased()
        if desc.contains("bệnh viện") || desc.contains("hospital") { return "cross.case.fill" }
        if desc.contains("trường") || desc.contains("school")      { return "graduationcap.fill" }
        if desc.contains("sân bay") || desc.contains("airport")    { return "airplane" }
        if desc.contains("nhà hàng") || desc.contains("restaurant"){ return "fork.knife" }
        if desc.contains("khách sạn") || desc.contains("hotel")    { return "bed.double.fill" }
        if desc.contains("xăng") || desc.contains("gas")           { return "fuelpump.fill" }
        if desc.contains("siêu thị") || desc.contains("market")    { return "cart.fill" }
        return "mappin.and.ellipse"
    }

    #if DEBUG
    @ViewBuilder
    private func debugOverlay(trace: FieldNavigationTraceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GPS acc: \(Int(trace.horizontalAccuracy))m | Spd: \(Int(trace.speed * 3.6))km/h")
            Text("Raw dist: \(Int(trace.rawNearestRouteDistance))m | Matched: \(Int(trace.matchedAlongRouteMeters))m")
            Text("Progress: \(Int(viewModel.navSession.displayProgressDistanceAlongRoute))m | Match: \(trace.matchConfidence)")
            Text("Phys Δ: \(Int(trace.physicalDisplacement))m | Match Δ: \(Int(trace.alongRouteAdvancement))m")
            Text("OffRoute: \(trace.offRouteState) (\(trace.offRouteReason))")
            Text("Maneuver: \(trace.currentUpcomingManeuverIndex) → \(Int(trace.distanceToUpcomingManeuver))m")
            Text("Reroute: \(trace.rerouteState)")
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.80))
        .cornerRadius(8)
        .allowsHitTesting(false)
    }
    #endif
}
