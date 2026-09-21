//
//  LocationTrackingProfile.swift
//  Explicit location tracking profiles, activity mapping, and power policies.
//

import CoreLocation
import Foundation

/// Pure enumeration of location tracking operational tiers.
public enum LocationTrackingProfile: String, Sendable, Equatable, CaseIterable {
    /// Non-navigating in background or updates completely halted.
    case suspended

    /// Foreground idle or searching: moderate accuracy, heading off, low energy.
    case foregroundPassive

    /// Route preview mode: sufficient accuracy for route origin, heading off.
    case routePreview

    /// Active turn-by-turn navigation: high-accuracy GPS, heading enabled, background tracking allowed.
    case activeNavigation
}

/// Concrete CLLocationManager configuration resolved for a given profile and transport mode.
public struct LocationTrackingConfiguration: Sendable, Equatable {
    public let profile: LocationTrackingProfile
    public let desiredAccuracy: CLLocationAccuracy
    public let distanceFilter: CLLocationDistance
    public let headingEnabled: Bool
    public let activityType: CLActivityType
    public let pausesLocationUpdatesAutomatically: Bool
    public let allowsBackgroundLocationUpdates: Bool
    public let showsBackgroundLocationIndicator: Bool

    public init(
        profile: LocationTrackingProfile,
        desiredAccuracy: CLLocationAccuracy,
        distanceFilter: CLLocationDistance,
        headingEnabled: Bool,
        activityType: CLActivityType,
        pausesLocationUpdatesAutomatically: Bool,
        allowsBackgroundLocationUpdates: Bool,
        showsBackgroundLocationIndicator: Bool
    ) {
        self.profile = profile
        self.desiredAccuracy = desiredAccuracy
        self.distanceFilter = distanceFilter
        self.headingEnabled = headingEnabled
        self.activityType = activityType
        self.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically
        self.allowsBackgroundLocationUpdates = allowsBackgroundLocationUpdates
        self.showsBackgroundLocationIndicator = showsBackgroundLocationIndicator
    }
}

/// Pure mapper from NavigationTransportMode to Core Location activity types.
public enum LocationActivityTypeMapper {
    public static func activityType(for mode: NavigationTransportMode) -> CLActivityType {
        switch mode {
        case .motorcycle, .auto:
            return .automotiveNavigation
        case .pedestrian:
            return .fitness
        case .bicycle:
            return .otherNavigation
        }
    }
}

/// Pure policy engine resolving tracking profiles based on application lifecycle and navigation state.
public enum LocationTrackingPolicy {

    /// Resolves active tracking profile based on navigation state and scene phase.
    public static func resolveProfile(state: NavigationState, isForeground: Bool) -> LocationTrackingProfile {
        if !isForeground {
            // Background policy: only active navigation maintains location tracking
            return state == .navigating ? .activeNavigation : .suspended
        }

        switch state {
        case .idle, .searching, .arrived:
            return .foregroundPassive
        case .routePreview:
            return .routePreview
        case .navigating:
            return .activeNavigation
        }
    }

    /// Computes exact CLLocationManager parameters for a given profile and transport mode.
    public static func configuration(
        for profile: LocationTrackingProfile,
        transportMode: NavigationTransportMode = .motorcycle
    ) -> LocationTrackingConfiguration {
        let activity = LocationActivityTypeMapper.activityType(for: transportMode)

        switch profile {
        case .suspended:
            return LocationTrackingConfiguration(
                profile: .suspended,
                desiredAccuracy: kCLLocationAccuracyThreeKilometers,
                distanceFilter: 1000.0,
                headingEnabled: false,
                activityType: activity,
                pausesLocationUpdatesAutomatically: true,
                allowsBackgroundLocationUpdates: false,
                showsBackgroundLocationIndicator: false
            )

        case .foregroundPassive:
            return LocationTrackingConfiguration(
                profile: .foregroundPassive,
                desiredAccuracy: kCLLocationAccuracyNearestTenMeters,
                distanceFilter: 10.0,
                headingEnabled: false,
                activityType: activity,
                pausesLocationUpdatesAutomatically: true,
                allowsBackgroundLocationUpdates: false,
                showsBackgroundLocationIndicator: false
            )

        case .routePreview:
            return LocationTrackingConfiguration(
                profile: .routePreview,
                desiredAccuracy: kCLLocationAccuracyNearestTenMeters,
                distanceFilter: 10.0,
                headingEnabled: false,
                activityType: activity,
                pausesLocationUpdatesAutomatically: true,
                allowsBackgroundLocationUpdates: false,
                showsBackgroundLocationIndicator: false
            )

        case .activeNavigation:
            return LocationTrackingConfiguration(
                profile: .activeNavigation,
                desiredAccuracy: kCLLocationAccuracyBestForNavigation,
                distanceFilter: kCLDistanceFilterNone,
                headingEnabled: true,
                activityType: activity,
                pausesLocationUpdatesAutomatically: false,
                allowsBackgroundLocationUpdates: true,
                showsBackgroundLocationIndicator: true
            )
        }
    }
}
