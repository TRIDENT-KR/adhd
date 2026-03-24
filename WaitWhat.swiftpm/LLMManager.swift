import Foundation
import MLX
import MLXNN

// 향후 Phi-3 등 다른 모델로 교체하거나 목업 모델을 사용할 때를 대비한 프로토콜
public protocol Predictable {
    func loadModel(modelID: String) async throws
    func generate(prompt: String) async throws -> String
    func clearMemory()
}

class LLMManager: ObservableObject, Predictable {
    @Published var isModelLoaded = false
    @Published var isGenerating = false
    
    // SLM 시스템 프롬프트: JSON 포맷 강제 및 카테고리 분류 
    private let systemPrompt = """
    너는 사용자의 음성 기록을 분석하여 일정과 루틴으로 분류하는 비서야.
    사용자의 입력을 분석하여 task, time, category 세 가지 키를 가진 JSON 배열로만 응답해.
    category는 딱 두 가지만 존재해: 'Routine'(매일 하는 일) 또는 'Appointment'(특정 시간/장소 약속).
    만약 시간이 명시되지 않았다면 null로 표시해.
    불필요한 설명은 절대 하지 말고 오직 JSON 포맷만 출력해.
    """
    
    // 추후 MLX Model과 Tokenizer 인스턴스가 저장될 위치
    // private var model: LlamaModel?
    // private var tokenizer: Tokenizer?
    
    /// Hugging Face에서 4-bit 양자화된 모델을 비동기로 로드합니다.
    func loadModel(modelID: String = "mlx-community/Meta-Llama-3-8B-Instruct-4bit") async throws {
        DispatchQueue.main.async {
            self.isModelLoaded = false
        }
        
        print("[\(modelID)] 모델의 가중치(4-bit Quantized)를 다운로드 및 로드하는 중입니다...")
        
        // 시뮬레이션 지연
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        DispatchQueue.main.async {
            self.isModelLoaded = true
            print("🚀 모델 로드가 완료되었습니다.")
        }
    }
    
    /// 주어진 프롬프트를 시스템 프롬프트와 묶어 Llama 3 챗 포맷으로 변환합니다.
    private func buildPrompt(userText: String) -> String {
        return """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>
        \(systemPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>
        \(userText)<|eot_id|><|start_header_id|>assistant<|end_header_id|>
        """
    }
    
    /// 주어진 프롬프트를 바탕으로 추론을 수행합니다.
    func generate(prompt: String) async throws -> String {
        guard isModelLoaded else {
            throw NSError(domain: "LLMManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "모델이 아직 로드되지 않았습니다."])
        }
        
        DispatchQueue.main.async {
            self.isGenerating = true
        }
        
        defer {
            // iOS 기기의 RAM 한계로 인해, 추론이 끝나면 항상 메모리 정리 및 상태 복구를 보장
            DispatchQueue.main.async {
                self.isGenerating = false
            }
            clearMemory()
        }
        
        let formattedPrompt = buildPrompt(userText: prompt)
        print("추론 시작 (포맷팅된 프롬프트):\n\(formattedPrompt)")
        
        // 🚀 추론 지연 및 완벽히 규격화된 JSON 응답 시뮬레이션
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // ex: "아 맞다, 내일 9시에 약속 있는데... 아 그전에 비타민도 먹어야지"
        let simulatedJSONResponse = """
        [
          {
            "task": "약속",
            "time": "내일 9시",
            "category": "Appointment"
          },
          {
            "task": "비타민 먹기",
            "time": null,
            "category": "Routine"
          }
        ]
        """
        
        return simulatedJSONResponse
    }
    
    /// iOS 기기의 RAM 제한을 방어하기 위해 GPU 캐시를 적절히 비워줍니다.
    func clearMemory() {
        print("🧹 MLX GPU 메모리 캐시를 정리합니다...")
        
        // MLX.GPU.clearCache() 기능 호출 (MLX-Swift 환경)
        MLX.GPU.clearCache()
    }
}
