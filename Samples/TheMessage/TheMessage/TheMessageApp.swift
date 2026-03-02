import SwiftUI

@main
struct TheMessageApp: App {
    @State private var store = MessageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
