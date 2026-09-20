//
//  GoongConfiguration.swift
//  Reads the Goong API key from the app bundle's Info.plist at runtime.
//
//  The key is injected via an Xcode build setting:
//    Info.plist entry: <key>GOONG_API_KEY</key><string>$(GOONG_API_KEY)</string>
//    Build setting:    GOONG_API_KEY = <your-key>   (via .xcconfig or CI secret)
//
//  CI unit tests: never instantiate GoongPlacesHTTPClient, so a real key is
//  never required. Tests inject MockGoongPlacesClient instead.
//

import Foundation

// MARK: - Configuration

public enum GoongConfiguration {

    /// Returns the Goong API key from the app bundle.
    ///
    /// Throws `GoongConfigError.missingAPIKey` when:
    /// - The key entry is absent from Info.plist
    /// - The value is an empty string
    /// - The value is an unexpanded build setting (starts with "$(")
    public static func apiKey() throws -> String {
        guard let key = Bundle.main.infoDictionary?["GOONG_API_KEY"] as? String,
              !key.isEmpty,
              !key.hasPrefix("$(") else {
            throw GoongConfigError.missingAPIKey
        }
        return key
    }
}

// MARK: - Errors

public enum GoongConfigError: LocalizedError, Equatable {
    case missingAPIKey

    public var errorDescription: String? {
        "GOONG_API_KEY not configured in Info.plist. " +
        "Set the build setting GOONG_API_KEY in your .xcconfig or CI environment."
    }
}
