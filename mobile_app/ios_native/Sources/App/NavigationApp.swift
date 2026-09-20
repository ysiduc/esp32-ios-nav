//
//  NavigationApp.swift
//  App entry point.
//

import SwiftUI

public extension ProcessInfo {
    static var isRunningUnitTests: Bool {
        processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        NSClassFromString("XCTestCase") != nil
    }
}

@main
public struct NavigationApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            if ProcessInfo.isRunningUnitTests {
                Color.clear
            } else {
                MainMapView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
