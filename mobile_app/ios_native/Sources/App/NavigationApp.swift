import SwiftUI

@main
public struct NavigationApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainMapView()
                .preferredColorScheme(.dark)
        }
    }
}
