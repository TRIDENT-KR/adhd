import Foundation
import SwiftUI
import Combine
import Supabase

struct AnalyzePayload: Codable {
    let text: String
}

class CloudLLMManager: ObservableObject {
    @Published var isProcessing = false
    

    
    func analyzeText(text: String) async throws -> [ParsedTask] {
        await MainActor.run { self.isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }
        
        do {
            let payload = AnalyzePayload(text: text)
            
            var headers: [String: String] = [:]
            if let session = try? await supabase.auth.session {
                headers["Authorization"] = "Bearer \(session.accessToken)"
            }
            
            let options = FunctionInvokeOptions(headers: headers, body: payload)
            
            let intents: [ParsedTask] = try await supabase.functions.invoke("analyze-task", options: options)
            return intents
        } catch {
            print("❌ Supabase Edge Function Error: \(error)")
            throw NSError(domain: "CloudLLM", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to parse task via Supabase: \(error.localizedDescription)"])
        }
    }
}
