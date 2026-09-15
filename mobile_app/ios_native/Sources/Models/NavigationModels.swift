import Foundation
import CoreLocation

/// Represents a turn-by-turn navigation step
public struct NavStep: Identifiable, Sendable {
    public let id: Int
    public let instruction: String
    public let streetName: String
    public let distanceMeters: Double
    public let durationSeconds: Double
    public let coordinate: CLLocationCoordinate2D
    public let maneuverType: ManeuverType

    public init(
        id: Int,
        instruction: String,
        streetName: String,
        distanceMeters: Double,
        durationSeconds: Double,
        coordinate: CLLocationCoordinate2D,
        maneuverType: ManeuverType
    ) {
        self.id = id
        self.instruction = instruction
        self.streetName = streetName
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.coordinate = coordinate
        self.maneuverType = maneuverType
    }
}

/// Represents a calculated navigation route
public struct NavRoute: Sendable {
    public let totalDistanceMeters: Double
    public let totalDurationSeconds: Double
    public let coordinates: [CLLocationCoordinate2D]
    public let steps: [NavStep]
    public let summary: String

    public init(
        totalDistanceMeters: Double,
        totalDurationSeconds: Double,
        coordinates: [CLLocationCoordinate2D],
        steps: [NavStep],
        summary: String
    ) {
        self.totalDistanceMeters = totalDistanceMeters
        self.totalDurationSeconds = totalDurationSeconds
        self.coordinates = coordinates
        self.steps = steps
        self.summary = summary
    }

    public var formattedDistance: String {
        if totalDistanceMeters >= 1000 {
            return String(format: "%.1f km", totalDistanceMeters / 1000.0)
        }
        return "\(Int(totalDistanceMeters.rounded())) m"
    }

    public var formattedDuration: String {
        let mins = Int((totalDurationSeconds / 60.0).rounded())
        if mins >= 60 {
            let hours = mins / 60
            let remainder = mins % 60
            if remainder == 0 { return "\(hours) giờ" }
            return "\(hours) giờ \(remainder) phút"
        }
        return "\(mins) phút"
    }
}

/// Real-time progress dispatched to BLE and UI HUD
public struct NavigationProgress: Sendable {
    public var maneuver: ManeuverType
    public var distanceToTurnMeters: UInt32
    public var remainingDistanceMeters: UInt32
    public var remainingEtaSeconds: UInt32
    public var currentSpeedKmh: UInt8
    public var speedLimitKmh: UInt8
    public var nextStreetName: String

    public init(
        maneuver: ManeuverType = .straight,
        distanceToTurnMeters: UInt32 = 0,
        remainingDistanceMeters: UInt32 = 0,
        remainingEtaSeconds: UInt32 = 0,
        currentSpeedKmh: UInt8 = 0,
        speedLimitKmh: UInt8 = 0,
        nextStreetName: String = ""
    ) {
        self.maneuver = maneuver
        self.distanceToTurnMeters = distanceToTurnMeters
        self.remainingDistanceMeters = remainingDistanceMeters
        self.remainingEtaSeconds = remainingEtaSeconds
        self.currentSpeedKmh = currentSpeedKmh
        self.speedLimitKmh = speedLimitKmh
        self.nextStreetName = nextStreetName
    }

    public var formattedDistanceToTurn: String {
        if distanceToTurnMeters >= 1000 {
            return String(format: "%.1f km", Double(distanceToTurnMeters) / 1000.0)
        }
        return "\(distanceToTurnMeters) m"
    }

    public var formattedRemainingDistance: String {
        if remainingDistanceMeters >= 1000 {
            return String(format: "%.1f km", Double(remainingDistanceMeters) / 1000.0)
        }
        return "\(remainingDistanceMeters) m"
    }

    public var formattedRemainingEta: String {
        let mins = Int(remainingEtaSeconds / 60)
        if mins >= 60 {
            return "\(mins / 60)h \(mins % 60)m"
        }
        return "\(mins) min"
    }
}
