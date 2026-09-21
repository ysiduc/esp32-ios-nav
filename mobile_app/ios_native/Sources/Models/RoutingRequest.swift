//
//  RoutingRequest.swift
//  Pure routing request and structured JSON serialization helper for Valhalla.
//

import CoreLocation
import Foundation

public struct RoutingRequest: Sendable, Equatable {
    public let origin: CLLocationCoordinate2D
    public let destination: CLLocationCoordinate2D
    public let profile: RoutingProfile
    public let requestedAlternatives: Int

    public init(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        profile: RoutingProfile,
        requestedAlternatives: Int = 2
    ) {
        self.origin = origin
        self.destination = destination
        self.profile = profile
        self.requestedAlternatives = max(0, min(requestedAlternatives, profile.maxAlternatives))
    }

    public static func == (lhs: RoutingRequest, rhs: RoutingRequest) -> Bool {
        return abs(lhs.origin.latitude - rhs.origin.latitude) < 1e-6 &&
               abs(lhs.origin.longitude - rhs.origin.longitude) < 1e-6 &&
               abs(lhs.destination.latitude - rhs.destination.latitude) < 1e-6 &&
               abs(lhs.destination.longitude - rhs.destination.longitude) < 1e-6 &&
               lhs.profile == rhs.profile &&
               lhs.requestedAlternatives == rhs.requestedAlternatives
    }
}

public enum ValhallaRequestBuilder {

    /// Build a valid Valhalla route request JSON string via structured JSONSerialization.
    /// Never uses manual string interpolation.
    public static func buildRequestJSON(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        profile: RoutingProfile,
        alternates: Int
    ) throws -> String {
        var root: [String: Any] = [
            "locations": [
                ["lon": origin.longitude, "lat": origin.latitude],
                ["lon": destination.longitude, "lat": destination.latitude]
            ],
            "costing": profile.valhallaCosting,
            "directions_options": [
                "language": "vi",
                "units": "kilometers",
                "narrative": true
            ],
            "format": "json"
        ]

        let boundedAlternates = max(0, min(alternates, profile.maxAlternatives))
        if boundedAlternates > 0 {
            root["alternates"] = boundedAlternates
        }

        if !profile.costingOptions.numericOptions.isEmpty {
            root["costing_options"] = [
                profile.valhallaCosting: profile.costingOptions.numericOptions
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "ValhallaRequestBuilder",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON dictionary to UTF-8"]
            )
        }
        return jsonString
    }
}
