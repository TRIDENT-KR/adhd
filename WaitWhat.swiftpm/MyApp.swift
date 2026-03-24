import SwiftUI

@main
struct WaitWhatApp: App {
    @StateObject private var taskManager = TaskManager()
    @StateObject private var cloudLLM = CloudLLMManager()
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(taskManager)
                .environmentObject(cloudLLM)
        }
    }
}
