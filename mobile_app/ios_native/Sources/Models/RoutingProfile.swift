//
//  RoutingProfile.swift
//  Pure routing profile models and costing option specifications.
//

import Foundation

public struct ProfileCostingOptions: Sendable, Equatable {
    public var numericOptions: [String: Double]

    public init(_ options: [String: Double] = [:]) {
        self.numericOptions = options
    }

    /// Motorcycle costing options tuned conservatively for Vietnamese road navigation:
    /// - use_highways = 0.5 (normal arterial roads permitted; Valhalla graph handles legal motorway restrictions)
    /// - use_tolls = 0.5 (allow toll roads if optimal)
    /// - use_trails = 0.0 (strongly discourage off-road trails/dirt footpaths)
    /// - use_tracks = 0.0 (strongly discourage agricultural/unpaved tracks)
    /// - use_ferry = 0.5 (allow standard river crossings)
    /// - use_living_streets = 0.5 (allow standard residential access)
    public static func motorcycle() -> ProfileCostingOptions {
        ProfileCostingOptions([
            "use_highways": 0.5,
            "use_tolls": 0.5,
            "use_trails": 0.0,
            "use_tracks": 0.0,
            "use_ferry": 0.5,
            "use_living_streets": 0.5
        ])
    }

    /// Standard car profile:
    /// - use_highways = 1.0 (favor higher classification roadways)
    /// - use_tolls = 1.0
    /// - use_trails = 0.0
    /// - use_tracks = 0.0
    /// - use_ferry = 0.5
    /// - use_living_streets = 0.5
    public static func auto() -> ProfileCostingOptions {
        ProfileCostingOptions([
            "use_highways": 1.0,
            "use_tolls": 1.0,
            "use_trails": 0.0,
            "use_tracks": 0.0,
            "use_ferry": 0.5,
            "use_living_streets": 0.5
        ])
    }

    /// Standard bicycle profile:
    /// - use_roads = 0.5
    /// - use_hills = 0.2 (moderately discourage steep grades)
    public static func bicycle() -> ProfileCostingOptions {
        ProfileCostingOptions([
            "use_roads": 0.5,
            "use_hills": 0.2
        ])
    }

    /// Standard pedestrian profile:
    /// - use_lit = 0.5 (mildly prefer lit pathways where tagged)
    public static func pedestrian() -> ProfileCostingOptions {
        ProfileCostingOptions([
            "use_lit": 0.5
        ])
    }
}

public enum FallbackCapability: Sendable, Equatable {
    case native
    case degradedApproximation(reason: String)
    case unsupported
}

public struct FallbackPolicy: Sendable, Equatable {
    public let allowMapKitFallback: Bool
    public let mapKitCapability: FallbackCapability

    public static let auto = FallbackPolicy(
        allowMapKitFallback: true,
        mapKitCapability: .native
    )

    public static let pedestrian = FallbackPolicy(
        allowMapKitFallback: true,
        mapKitCapability: .native
    )

    public static let motorcycle = FallbackPolicy(
        allowMapKitFallback: true,
        mapKitCapability: .degradedApproximation(reason: "MapKit không hỗ trợ xe máy, sử dụng lộ trình ô tô tạm thời")
    )

    public static let bicycle = FallbackPolicy(
        allowMapKitFallback: true,
        mapKitCapability: .degradedApproximation(reason: "MapKit không hỗ trợ xe đạp, sử dụng lộ trình đi bộ tạm thời")
    )

    public init(allowMapKitFallback: Bool, mapKitCapability: FallbackCapability) {
        self.allowMapKitFallback = allowMapKitFallback
        self.mapKitCapability = mapKitCapability
    }
}

public struct RoutingProfile: Sendable, Equatable {
    public let id: String
    public let transportMode: NavigationTransportMode
    public let valhallaCosting: String
    public let costingOptions: ProfileCostingOptions
    public let maxAlternatives: Int
    public let fallbackPolicy: FallbackPolicy

    public init(
        id: String,
        transportMode: NavigationTransportMode,
        valhallaCosting: String,
        costingOptions: ProfileCostingOptions,
        maxAlternatives: Int = 2,
        fallbackPolicy: FallbackPolicy
    ) {
        self.id = id
        self.transportMode = transportMode
        self.valhallaCosting = valhallaCosting
        self.costingOptions = costingOptions
        self.maxAlternatives = maxAlternatives
        self.fallbackPolicy = fallbackPolicy
    }

    public static func profile(for mode: NavigationTransportMode) -> RoutingProfile {
        switch mode {
        case .motorcycle:
            return RoutingProfile(
                id: "motorcycle_standard",
                transportMode: .motorcycle,
                valhallaCosting: "motorcycle",
                costingOptions: .motorcycle(),
                maxAlternatives: 2,
                fallbackPolicy: .motorcycle
            )
        case .auto:
            return RoutingProfile(
                id: "auto_standard",
                transportMode: .auto,
                valhallaCosting: "auto",
                costingOptions: .auto(),
                maxAlternatives: 2,
                fallbackPolicy: .auto
            )
        case .bicycle:
            return RoutingProfile(
                id: "bicycle_standard",
                transportMode: .bicycle,
                valhallaCosting: "bicycle",
                costingOptions: .bicycle(),
                maxAlternatives: 2,
                fallbackPolicy: .bicycle
            )
        case .pedestrian:
            return RoutingProfile(
                id: "pedestrian_standard",
                transportMode: .pedestrian,
                valhallaCosting: "pedestrian",
                costingOptions: .pedestrian(),
                maxAlternatives: 2,
                fallbackPolicy: .pedestrian
            )
        }
    }
}
