import SwiftUI
import OvertureDesign
import OvertureKit

@main
struct OvertureApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Overture", systemImage: "square.grid.3x3") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Home ⇄ board navigation shell. Fleshed out as OvertureKit stores land.
struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Overture",
                systemImage: "square.grid.3x3",
                description: Text("Project tiles land here — M1 in progress."))
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Settings — populated in M1.")
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

struct MenuBarView: View {
    var body: some View {
        Text("No agents running")
            .padding()
    }
}
