import SwiftUI

@main
struct StandUpReminderApp: App {
    @StateObject private var viewModel = ReminderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
