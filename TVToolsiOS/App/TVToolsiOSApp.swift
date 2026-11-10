import SwiftUI

@main
struct TVToolsiOSApp: App {
    @StateObject private var session = TVSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
