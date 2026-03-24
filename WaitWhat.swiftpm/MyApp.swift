import SwiftUI
import SwiftData

@main
struct WaitWhatApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .modelContainer(for: [RoutineTask.self, PlannerEvent.self])
        }
    }
}
