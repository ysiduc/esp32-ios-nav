//
//  SearchModels.swift
//  Provider-neutral search models and abstraction protocol.
//

import CoreLocation
import Foundation

// MARK: - Search Prediction

/// A provider-independent autocomplete prediction.
public struct SearchPrediction: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String

    public init(id: String = UUID().uuidString, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    /// Primary display text (e.g. place or street name).
    public var mainText: String { title }

    /// Secondary display text (e.g. district, city).
    public var secondaryText: String { subtitle }

    /// Full composite description.
    public var description: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    public static func == (lhs: SearchPrediction, rhs: SearchPrediction) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
    }
}

// MARK: - Resolved Place

/// A fully resolved place with title, address, and physical coordinate.
public struct ResolvedPlace: Sendable, Equatable {
    public let id: String
    public let name: String
    public let formattedAddress: String
    public let coordinate: CLLocationCoordinate2D

    public init(
        id: String = UUID().uuidString,
        name: String,
        formattedAddress: String,
        coordinate: CLLocationCoordinate2D
    ) {
        self.id = id
        self.name = name
        self.formattedAddress = formattedAddress
        self.coordinate = coordinate
    }

    public static func == (lhs: ResolvedPlace, rhs: ResolvedPlace) -> Bool {
        abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 1e-6 &&
        abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 1e-6 &&
        lhs.name == rhs.name &&
        lhs.formattedAddress == rhs.formattedAddress
    }
}

// MARK: - Place Search Service Protocol

/// Abstract service protocol for autocomplete and place resolution.
@MainActor
public protocol PlaceSearchServiceProtocol: AnyObject {
    var predictions: [SearchPrediction] { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get }

    var userLocation: CLLocationCoordinate2D? { get set }
    var onPredictionsChanged: (([SearchPrediction]) -> Void)? { get set }

    func updateQuery(_ query: String)
    func cancelAutocomplete()
    func clearPredictions()
    func resetAll()
    func resolve(prediction: SearchPrediction) async throws -> ResolvedPlace
}
