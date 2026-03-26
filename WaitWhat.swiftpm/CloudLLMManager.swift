import Foundation
import Supabase

struct AnalyzePayload: Codable {
    let text: String
}

class CloudLLMManager: ObservableObject {
    @Published var isProcessing = false
    
    private var supabaseUrl: URL {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let urlString = dict["SUPABASE_URL"] as? String,
              let url = URL(string: urlString) else {
            return URL(string: "https://example.supabase.co")!
        }
        return url
    }
    
    private var supabaseAnonKey: String {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["SUPABASE_ANON_KEY"] as? String else {
            return "ANON_KEY_PLACEHOLDER"
        }
        return key
    }
    
    private lazy var supabase = SupabaseClient(supabaseURL: supabaseUrl, supabaseKey: supabaseAnonKey)
    
    func analyzeText(text: String) async throws -> [ParsedTask] {
        await MainActor.run { self.isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }
        
        do {
            let payload = AnalyzePayload(text: text)
            let options = FunctionInvokeOptions(body: payload)
            
            let intents: [ParsedTask] = try await supabase.functions.invoke("analyze-task", options: options)
            return intents
        } catch {
            print("❌ Supabase Edge Function Error: \(error)")
            throw NSError(domain: "CloudLLM", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to parse task via Supabase: \(error.localizedDescription)"])
        }
    }
}
