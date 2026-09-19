//
//  SearchResultItem.swift
//  Legacy model kept for BLE packet compatibility.
//  New code uses GoongPrediction + GoongPlace from GoongSearchService.swift.
//

import CoreLocation
import Foundation

/// Legacy search result model — used only by BLEManager.sendNavigationPacket indirectly.
/// New UI code uses GoongPrediction + GoongPlace.
public struct SearchResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: CLLocationCoordinate2D

    public init(id: String = UUID().uuidString, name: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool { lhs.id == rhs.id }
}
