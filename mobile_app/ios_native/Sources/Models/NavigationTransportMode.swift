//
//  NavigationTransportMode.swift
//  Strongly typed navigation transport mode enum for routing boundaries.
//

import Foundation

public enum NavigationTransportMode: String, Sendable, CaseIterable, Equatable, Hashable {
    case motorcycle
    case auto
    case bicycle
    case pedestrian

    public var displayName: String {
        switch self {
        case .motorcycle: return "Xe máy"
        case .auto:       return "Ô tô"
        case .bicycle:    return "Xe đạp"
        case .pedestrian: return "Đi bộ"
        }
    }

    public var iconName: String {
        switch self {
        case .motorcycle: return "bicycle"
        case .auto:       return "car.fill"
        case .bicycle:    return "bicycle"
        case .pedestrian: return "figure.walk"
        }
    }

    /// Convert from loose/legacy UI string safely.
    public init(costingValue: String) {
        switch costingValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "auto", "car", "automobile", "ô tô", "oto":
            self = .auto
        case "bicycle", "bike", "xe đạp", "xe dap":
            self = .bicycle
        case "pedestrian", "walk", "walking", "đi bộ", "di bo":
            self = .pedestrian
        default:
            self = .motorcycle
        }
    }
}
