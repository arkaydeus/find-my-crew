import SwiftUI

@main
struct FindMyCrewApp: App {
    @State private var model = AppModel()

    init() { DroppedItems.purgeStaleCopies() }

    var body: some Scene {
        Window("Find My Crew", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
