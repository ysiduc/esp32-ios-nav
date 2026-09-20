//
//  NavigationApp.swift
//  App entry point.
//

import SwiftUI

@main
public struct NavigationApp: App {
    public init() {}

    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        NSClassFromString("XCTestCase") != nil
    }

    public var body: some Scene {
        WindowGroup {
            if isTesting {
                Text("Running Unit Tests...")
            } else {
                MainMapView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
