//
//  BLEScanGenerationGuard.swift
//  Thread-safe / deterministic generation guard for BLE scanning lifecycle.
//

import Foundation

/// Pure generation guard that prevents stale delayed scan callbacks
/// (e.g. 5-second broader scan fallback) from mutating newer scan sessions.
public struct BLEScanGenerationGuard: Sendable {
    public private(set) var generation: UInt = 0

    public init() {}

    /// Begins a new scan generation, invalidating any previous generation token.
    @discardableResult
    public mutating func begin() -> UInt {
        generation &+= 1
        return generation
    }

    /// Explicitly invalidates the current scan generation on stop or reset.
    public mutating func invalidate() {
        generation &+= 1
    }

    /// Verifies whether the provided token matches the current active scan generation.
    public func isCurrent(_ token: UInt) -> Bool {
        return token == generation
    }
}
