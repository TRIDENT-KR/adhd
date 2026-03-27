import Foundation
import SwiftUI
import Combine
import AVFoundation
import Speech

// MARK: - Voice Error Types
enum VoiceError: Equatable {
    case emptyTranscription
    case recognitionFailed
    case networkError
    case apiError(String)
    case permissionDenied

    var message: String {
        switch self {
        case .emptyTranscription:
            return L.voice.errorNotHeard
        case .recognitionFailed:
            return L.voice.errorRecognitionFailed
        case .networkError:
            return L.voice.errorNetwork
        case .apiError:
            return L.voice.errorApi
        case .permissionDenied:
            return L.voice.errorPermission
        }
    }
}

// MARK: - Mic Input Mode
enum MicInputMode: String {
    case tapToggle = "tap"    // 탭해서 시작/종료
    case holdToTalk = "hold"  // 누르고 있는 동안만 녹음
}

class VoiceInputManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var isListening: Bool = false
    @Published var recognizedText: String = ""
    @Published var audioPower: CGFloat = 0.0 // 0.0 to 1.0 for ripple effect
    @Published var errorMessage: String?

    // For Vibe Check logic (transitioning to inference)
    @Published var isProcessing: Bool = false

    // Recording duration timer
    @Published var recordingDuration: TimeInterval = 0
    private var recordingTimer: Timer?
    static let maxRecordingDuration: TimeInterval = 30 // 최대 30초

    // Silence countdown
    @Published var silenceCountdown: Int = 0  // 0이면 비활성, 3→2→1→전송
    private var silenceTimer: Timer?
    private var lastSpeechTime: Date = Date()
    private static let silenceThreshold: TimeInterval = 2.0  // 2초 침묵 후 카운트다운 시작
    private static let countdownSeconds: Int = 3

    // Error feedback
    @Published var lastError: VoiceError?

    // Completion handler for when recording successfully finishes
    var onSpeechFinalized: ((String) -> Void)?

    @Published var currentLocaleId: String = "en-US"

    // Mic input mode
    @Published var micMode: MicInputMode = {
        MicInputMode(rawValue: UserDefaults.standard.string(forKey: "micInputMode") ?? "tap") ?? .tapToggle
    }()

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// UserDefaults Keys
    static let speechLocaleKey = "speechLocale"
    static let enabledLocalesKey = "enabledLocales"

    /// 설정에서 활성화한 언어 목록
    static var enabledLocales: [String] {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: enabledLocalesKey)
            return (saved?.isEmpty == false) ? saved! : ["en-US"]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledLocalesKey)
        }
    }

    override init() {
        super.init()
        let localeId = UserDefaults.standard.string(forKey: Self.speechLocaleKey) ?? "en-US"
        currentLocaleId = localeId
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        speechRecognizer?.delegate = self
        requestPermissions()
    }

    /// 활성화된 언어 목록 내에서 다음 언어로 순환 전환
    func cycleLanguage() {
        let locales = Self.enabledLocales
        guard locales.count > 1 else { return }
        let currentIndex = locales.firstIndex(of: currentLocaleId) ?? 0
        let nextIndex = (currentIndex + 1) % locales.count
        let nextLocale = locales[nextIndex]
        setLocale(nextLocale)
    }

    /// 특정 locale로 전환
    func setLocale(_ localeId: String) {
        currentLocaleId = localeId
        UserDefaults.standard.set(localeId, forKey: Self.speechLocaleKey)
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        speechRecognizer?.delegate = self
    }
    
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    AVAudioApplication.requestRecordPermission { granted in
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
    
    func setMicMode(_ mode: MicInputMode) {
        micMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "micInputMode")
    }

    func startListening() {
        // Reset state
        recognizedText = ""
        errorMessage = nil
        lastError = nil
        isListening = true
        isProcessing = false
        audioPower = 0.0
        recordingDuration = 0
        silenceCountdown = 0
        lastSpeechTime = Date()
        startRecordingTimer()
        startSilenceDetection()
        
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
                    // 텍스트가 변경될 때마다 침묵 타이머 리셋
                    self?.lastSpeechTime = Date()
                    self?.silenceCountdown = 0
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
            silenceCountdown = 0
            stopRecordingTimer()
            stopSilenceDetection()

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
        silenceCountdown = 0
        stopRecordingTimer()
        stopSilenceDetection()
    }

    private func finalizeAndProceed() {
        // Pass the recognized text over to the closure for SLM processing
        print("Finalizing text for pipeline: \(recognizedText)")

        if recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastError = .emptyTranscription
            isProcessing = false
            return
        }

        onSpeechFinalized?(recognizedText)
    }

    // MARK: - Recording Timer
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.recordingDuration += 0.1
                // 최대 녹음 시간 초과 시 자동 종료
                if self.recordingDuration >= Self.maxRecordingDuration {
                    self.stopListening()
                }
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Silence Detection & Countdown
    private func startSilenceDetection() {
        // tap 모드에서만 침묵 감지 (hold 모드는 손 떼면 바로 종료)
        guard micMode == .tapToggle else { return }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isListening else { return }
            DispatchQueue.main.async {
                // 텍스트가 비어있으면 침묵 카운트다운 하지 않음
                guard !self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                let silenceDuration = Date().timeIntervalSince(self.lastSpeechTime)

                if silenceDuration >= Self.silenceThreshold {
                    let elapsed = Int(silenceDuration - Self.silenceThreshold)
                    let remaining = Self.countdownSeconds - elapsed

                    if remaining > 0 {
                        self.silenceCountdown = remaining
                    } else {
                        // 카운트다운 완료 → 자동 전송
                        self.silenceCountdown = 0
                        self.stopListening()
                    }
                } else {
                    self.silenceCountdown = 0
                }
            }
        }
    }

    private func stopSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}
