import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import Hub

public protocol Predictable {
    func loadModel(modelID: String) async throws
    func generate(prompt: String) async throws -> String
    func clearMemory()
}

class LLMManager: ObservableObject, Predictable {
    @Published var isModelLoaded = false
    @Published var isGenerating = false
    
    // SLM 시스템 프롬프트: JSON 포맷 강제
    private let systemPrompt = """
    너는 사용자의 음성 기록을 분석하여 일정과 루틴으로 분류하는 비서야.
    사용자의 입력을 분석하여 task, time, category 세 가지 키를 가진 JSON 배열로만 응답해.
    category는 꼭 "Routine"(매일 하는 일) 또는 "Appointment"(특정 시간/장소 약속) 둘 중 하나여야 해.
    시간이 없으면 time은 null로 표시해. 설명은 일절 생략하고 반드시 순수한 JSON 배열 포맷만 출력해.
    """
    
    // MLXLLM 추론 엔진 속성
    private var modelContainer: ModelContainer?
    
    /// Hugging Face에서 양자화된 Llama 3.2 1B 모델 가중치를 로드합니다.
    func loadModel(modelID: String = "mlx-community/Llama-3.2-1B-Instruct-4bit") async throws {
        DispatchQueue.main.async { self.isModelLoaded = false }
        print("[\(modelID)] 모델의 가중치를 다운로드 및 로드하는 중입니다...")
        
        let hub = HubApi()
        let configuration = ModelConfiguration(id: modelID)
        
        // 메모리 제한 완화 (모바일 환경에 따라 조율)
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        
        // LLMModelFactory를 이용해 Hub에서 다운로드하고 ModelContainer 생성
        let container = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration) { progress in
            print("Downloading... \(Int(progress.fractionCompleted * 100))%")
        }
        
        self.modelContainer = container
        
        DispatchQueue.main.async {
            self.isModelLoaded = true
            print("🚀 모델 로드가 완료되었습니다. (MLX On-Device)")
        }
    }
    
    func generate(prompt: String) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "LLMManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "모델이 아직 로드되지 않았습니다."])
        }
        
        DispatchQueue.main.async { self.isGenerating = true }
        
        defer {
            DispatchQueue.main.async { self.isGenerating = false }
            clearMemory()
        }
        
        // MLXLMCommon의 기능인 UserInput 메세징 활용
        let chat: [Chat.Message] = [
            .system(systemPrompt),
            .user(prompt)
        ]
        
        let userInput = UserInput(chat: chat)
        let lmInput = try await container.prepare(input: userInput)
        let parameters = GenerateParameters(temperature: 0.1)
        
        print("추론 시작. Input 토큰 수: \(lmInput.text.tokens.size)")
        
        let stream = try await container.generate(input: lmInput, parameters: parameters)
        var iterator = stream.makeAsyncIterator()
        
        var generatedText = ""
        while let next = await iterator.next() {
            if let chunk = next.chunk, !chunk.isEmpty {
                generatedText += chunk
            }
        }
        
        // 불필요한 마크다운 백틱(`) 제거나 텍스트 다듬기
        let cleanedJSON = generatedText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        print("추론 완료: \(cleanedJSON)")
        return cleanedJSON
    }
    
    func clearMemory() {
        print("🧹 MLX GPU 메모리 캐시를 정리합니다...")
        MLX.GPU.clearCache()
    }
}
