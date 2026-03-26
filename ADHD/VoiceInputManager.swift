import Foundation
import SwiftUI
import Combine
import AVFoundation
import Speech
import SwiftUI

class VoiceInputManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var isListening: Bool = false
    @Published var recognizedText: String = ""
    @Published var audioPower: CGFloat = 0.0 // 0.0 to 1.0 for ripple effect
    @Published var errorMessage: String?
    
    // For Vibe Check logic (transitioning to inference)
    @Published var isProcessing: Bool = false
    
    // Completion handler for when recording successfully finishes
    var onSpeechFinalized: ((String) -> Void)?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) // Adjust for user language preference
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    override init() {
        super.init()
        speechRecognizer?.delegate = self
        requestPermissions()
    }
    
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        if !granted {
                            self.errorMessage = "마이크 사용 권한이 필요합니다."
                        }
                    }
                case .denied, .restricted, .notDetermined:
                    self.errorMessage = "음성 인식 권한이 필요합니다."
                @unknown default:
                    self.errorMessage = "알 수 없는 권한 오류가 발생했습니다."
                }
            }
        }
    }
    
    func toggleListening() {
        if audioEngine.isRunning {
            stopListening()
        } else {
            startListening()
        }
    }
    
    func startListening() {
        // Reset state
        recognizedText = ""
        errorMessage = nil
        isListening = true
        isProcessing = false
        audioPower = 0.0
        
        // Cancel any previous task
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.errorMessage = "오디오 세션을 설정할 수 없습니다."
            self.isListening = false
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            self.errorMessage = "음성 인식을 초기화할 수 없습니다."
            self.isListening = false
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true // Real-time intermediate results
        
        let inputNode = audioEngine.inputNode
        
        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            var isFinal = false
            
            if let result = result {
                DispatchQueue.main.async {
                    self?.recognizedText = result.bestTranscription.formattedString
                }
                isFinal = result.isFinal
            }
            
            if error != nil || isFinal {
                self?.stopHandling()
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            self?.recognitionRequest?.append(buffer)
            self?.updateAudioPower(buffer: buffer)
        }
        
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
        } catch {
            self.errorMessage = "오디오 엔진을 시작할 수 없습니다."
            self.stopListening()
        }
    }
    
    private func updateAudioPower(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        let channelDataValueArray = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        
        // Calculate RMS (Root Mean Square)
        var sumSquares: Float = 0
        for sample in channelDataValueArray {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        
        // Convert to decibels
        let avgPower = 20 * log10(rms)
        
        // Normalize power from roughly -50dB to 0dB into 0.0 to 1.0 range
        let minDb: Float = -50.0
        let normalized = max(0.0, min(1.0, (avgPower - minDb) / -minDb))
        
        DispatchQueue.main.async {
            self.audioPower = CGFloat(normalized)
        }
    }
    
    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            isListening = false
            audioPower = 0.0
            
            // Vibe Check: Finish quickly when stopped, finalizing text to prepare for Llama 3 8b inference
            isProcessing = true
            finalizeAndProceed()
        }
    }
    
    private func stopHandling() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        audioPower = 0.0
    }
    
    private func finalizeAndProceed() {
        // Pass the recognized text over to the closure for SLM processing
        print("Finalizing text for pipeline: \(recognizedText)")
        onSpeechFinalized?(recognizedText)
    }
}
