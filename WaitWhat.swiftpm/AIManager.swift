import Foundation

@Observable
class AIManager {
    var isThinking: Bool = false
    
    struct AIParsedResult: Codable {
        let category: String
        let task: String
        let time: String?
        let datetime: String?
    }
    
    func processInstruction(text: String) async -> AIParsedResult? {
        isThinking = true
        defer { isThinking = false }
        
        let systemPrompt = """
        당신은 극단적인 미니멀리즘과 Voice-First UX를 지향하는 일정 관리 애플리케이션의 AI 코어입니다.
        사용자의 발화를 분석하여 'routine'과 'planner' 중 하나로 분류하고, 
        반드시 아래 형식의 순수 JSON 문자열만 반환해야 합니다. 다른 텍스트는 절대 포함하지 마세요.
        
        - 'routine': 매일 반복되거나 시간만 지정된 일회성 할 일
          예시: {"category": "routine", "task": "아침 약 먹기", "time": "08:00"}
          
        - 'planner': 특정 날짜와 시간에 종속된 약속 또는 미팅
          예시: {"category": "planner", "task": "강남역 미팅", "datetime": "2026-03-25T15:00:00"}
        """
        
        // MLX Swift 기반의 Phi-3 Mini 3.8B (4-bit 양자화) 모델 로드 및 추론 로직이 이곳에 들어갑니다.
        // 현재는 개발자들이 병렬 작업을 할 수 있도록 스캐폴딩 파사드(Facade) 형태로 구성했습니다.
        
        // TODO: MLX.generate() 등을 활용하여 실제 로컬 추론을 연결하세요.
        // 아래는 시뮬레이션 코드입니다.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        
        var simulatedJson = ""
        if text.contains("미팅") || text.contains("약속") || text.contains("일정") {
            // Planner
            simulatedJson = "{\"category\": \"planner\", \"task\": \"\\(text)\", \"datetime\": \"2026-03-25T15:00:00\"}"
        } else {
            // Routine
            simulatedJson = "{\"category\": \"routine\", \"task\": \"\\(text)\", \"time\": \"09:00\"}"
        }
        
        return decodeResult(jsonString: simulatedJson)
    }
    
    private func decodeResult(jsonString: String) -> AIParsedResult? {
        let decoder = JSONDecoder()
        if let data = jsonString.data(using: .utf8),
           let result = try? decoder.decode(AIParsedResult.self, from: data) {
            return result
        }
        print("JSON Decoding Failed for: \\(jsonString)")
        return nil
    }
}
