//
//  NavigationReplaySample.swift
//  Pure timestamped GPS sample model for deterministic navigation replay.
//

import CoreLocation
import Foundation

public struct NavigationReplaySample: Sendable, Equatable {
    public let timestamp: Date
    public let coordinate: CLLocationCoordinate2D
    public let horizontalAccuracy: Double
    public let speed: Double
    public let course: Double
    public let altitude: Double

    public init(
        timestamp: Date,
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: Double = 5.0,
        speed: Double = 10.0, // 36 km/h (~10 m/s)
        course: Double = 0.0,
        altitude: Double = 10.0
    ) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.altitude = altitude
    }

    public static func == (lhs: NavigationReplaySample, rhs: NavigationReplaySample) -> Bool {
        return lhs.timestamp == rhs.timestamp &&
               abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 1e-6 &&
               abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 1e-6 &&
               abs(lhs.horizontalAccuracy - rhs.horizontalAccuracy) < 1e-3 &&
               abs(lhs.speed - rhs.speed) < 1e-3 &&
               abs(lhs.course - rhs.course) < 1e-3
    }

    public func toCLLocation() -> CLLocation {
        return CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: 5.0,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}
