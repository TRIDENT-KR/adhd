import SwiftUI

@main
struct WaitWhatApp: App {
    @StateObject private var taskManager = TaskManager()
    @StateObject private var cloudLLM = CloudLLMManager()
    @StateObject private var authManager = AuthManager()
    
    var body: some Scene {
        WindowGroup {
            if authManager.session != nil {
                MainTabView()
                    .environmentObject(taskManager)
                    .environmentObject(cloudLLM)
                    .environmentObject(authManager)
            } else {
                LoginView()
                    .environmentObject(authManager)
            }
        }
    }
}
