import SwiftUI

@main
struct StandUpReminderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ReminderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 560, minHeight: 420)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.refreshFromStore()
            }
        }
    }
}
