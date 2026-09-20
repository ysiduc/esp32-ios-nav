//
//  NavigationModels.swift
//  Shared model definitions.
//

import CoreLocation
import Foundation

/// Immutable navigation destination frozen for the active navigation lifecycle.
public struct NavigationDestination: Equatable, Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let name: String?
    public let placeID: String?

    public init(coordinate: CLLocationCoordinate2D, name: String? = nil, placeID: String? = nil) {
        self.coordinate = coordinate
        self.name = name
        self.placeID = placeID
    }

    public static func == (lhs: NavigationDestination, rhs: NavigationDestination) -> Bool {
        return abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 0.000001 &&
               abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 0.000001 &&
               lhs.name == rhs.name &&
               lhs.placeID == rhs.placeID
    }
}
