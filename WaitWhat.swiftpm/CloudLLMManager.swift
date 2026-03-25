import Foundation

class CloudLLMManager: ObservableObject {
    @Published var isProcessing = false
    
    private var apiKey: String {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["GEMINI_API_KEY"] as? String,
              !key.isEmpty, key != "YOUR_GEMINI_API_KEY_HERE" else {
            print("❌ Config.plist에서 GEMINI_API_KEY를 찾을 수 없거나 기본값입니다.")
            return ""
        }
        return key
    }
    
    // Gemini 1.5 Flash endpoint (generateContent REST API)
    private var endpoint: String {
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
    }
    
    func analyzeText(text: String) async throws -> ParsedTask {
        let key = apiKey
        guard !key.isEmpty else {
            throw NSError(domain: "CloudLLM", code: 401, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY가 설정되지 않았습니다. Config.plist를 확인하세요."])
        }
        
        await MainActor.run { self.isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }
        
        let systemInstruction = """
        너는 사용자의 횡설수설하는 음성 기록을 분석하는 비서야.
        오직 task(할 일 이름), time(시간, 없으면 null), category('Routine' 또는 'Appointment') 이 3개의 키를 가진 JSON 객체로만 응답해.
        절대 다른 말은 덧붙이지 마.
        """
        
        // Gemini REST payload
        let payload: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [
                ["role": "user", "parts": [["text": text]]]
            ],
            "generationConfig": [
                "response_mime_type": "application/json",
                "temperature": 0.2
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            print("❌ Gemini API Error: \(errorMsg)")
            throw NSError(domain: "CloudLLM", code: (response as? HTTPURLResponse)?.statusCode ?? 500,
                          userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // Gemini 응답 구조: candidates[0].content.parts[0].text
        let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = responseDict?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let jsonString = parts.first?["text"] as? String else {
            throw NSError(domain: "CloudLLM", code: 0, userInfo: [NSLocalizedDescriptionKey: "Gemini 응답 형식을 파싱할 수 없습니다."])
        }
        
        guard let innerData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "CloudLLM", code: 0, userInfo: [NSLocalizedDescriptionKey: "JSON 문자열 변환 실패"])
        }
        
        let parsedTask = try JSONDecoder().decode(ParsedTask.self, from: innerData)
        return parsedTask
    }
}
