import Foundation
import CoreLocation
import MapKit

/// Routing Service using Apple MKDirections — 100% free, no API key, built into iOS.
/// Quality is equivalent to Apple Maps (very accurate in Vietnam).
public final class ValhallaRoutingService: Sendable {
    public init() {}

    /// Calculate a turn-by-turn route using Apple MKDirections.
    /// - Parameters:
    ///   - start: Starting coordinate
    ///   - destination: Destination coordinate
    ///   - costing: "car", "bike" — maps to MKDirectionsTransportType
    public func calculateRoute(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "bike"
    ) async throws -> (route: NavRoute, rawJson: Data) {

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.requestsAlternateRoutes = false

        // Transport type
        switch costing.lowercased() {
        case "walking", "pedestrian":
            request.transportType = .walking
        default:
            // MKDirections does not have motorcycle type — use automobile
            // Apple Maps routes for automobile also work well for motorbikes in VN
            request.transportType = .automobile
        }

        let directions = MKDirections(request: request)
        let response: MKDirections.Response

        do {
            response = try await directions.calculate()
        } catch {
            print("[MKDirections] Routing error: \(error.localizedDescription)")
            throw error
        }

        guard let mkRoute = response.routes.first else {
            throw URLError(.cannotParseResponse)
        }

        // --- Extract full polyline coordinates ---
        let pointCount = mkRoute.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        mkRoute.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))

        let totalDistanceMeters = mkRoute.distance
        let totalDurationSec    = mkRoute.expectedTravelTime

        // --- Parse MKRoute steps into NavStep ---
        var steps: [NavStep] = []
        var consumedCoordIdx = 0

        for (index, mkStep) in mkRoute.steps.enumerated() {
            let distMeters  = mkStep.distance
            let instruction = mkStep.instructions
            let streetName  = mkStep.notice ?? mkStep.instructions

            // Find the coordinate at the END of this step's polyline (= turn point)
            let stepPtCount = mkStep.polyline.pointCount
            var stepCoords  = [CLLocationCoordinate2D](repeating: .init(), count: stepPtCount)
            mkStep.polyline.getCoordinates(&stepCoords, range: NSRange(location: 0, length: stepPtCount))

            let turnCoord = stepCoords.last ?? start
            consumedCoordIdx = min(consumedCoordIdx + stepPtCount, pointCount - 1)

            let maneuver = ManeuverType.fromMKInstruction(instruction)

            // Duration per step (proportional to distance)
            let stepDuration = totalDurationSec * (distMeters / max(totalDistanceMeters, 1))

            steps.append(NavStep(
                id: index,
                instruction: instruction,
                streetName: streetName,
                distanceMeters: distMeters,
                durationSeconds: stepDuration,
                coordinate: turnCoord,
                maneuverType: maneuver
            ))
        }

        let navRoute = NavRoute(
            totalDistanceMeters: totalDistanceMeters,
            totalDurationSeconds: totalDurationSec,
            coordinates: coords,
            steps: steps,
            summary: mkRoute.name.isEmpty ? "Lộ trình Apple Maps" : mkRoute.name
        )

        print("[MKDirections] Route: \(String(format: "%.1f", totalDistanceMeters/1000))km, \(steps.count) steps, via \(mkRoute.name)")

        // MKDirections has no raw JSON — return empty Data
        return (route: navRoute, rawJson: Data())
    }
}
