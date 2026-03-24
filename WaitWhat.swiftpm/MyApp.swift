import SwiftUI

@main
struct WaitWhatApp: App {
    @StateObject private var taskManager = TaskManager()
    @StateObject private var llmManager = LLMManager()
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(taskManager)
                .environmentObject(llmManager)
                .task {
                    try? await llmManager.loadModel(modelID: "mlx-community/Meta-Llama-3-8B-Instruct-4bit")
                }
        }
    }
}
