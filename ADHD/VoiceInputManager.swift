import Foundation
import SwiftUI
import UIKit
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

    @Published var currentLocaleId: String = "ko-KR"

    // Mic input mode
    @Published var micMode: MicInputMode = {
        MicInputMode(rawValue: UserDefaults.standard.string(forKey: "micInputMode") ?? "tap") ?? .tapToggle
    }()
    private var micModeObserver: AnyCancellable?
    private var backgroundObserver: AnyCancellable?

    // Audio power downsampling: 4프레임당 1회만 계산
    private let audioFrameLock = NSLock()
    private var audioFrameCount: Int = 0
    private static let audioPowerSampleRate = 4

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private lazy var audioEngine = AVAudioEngine()
    private var didPrepare = false

    /// UserDefaults Keys
    static let speechLocaleKey = "speechLocale"

    override init() {
        super.init()
        let localeId = UserDefaults.standard.string(forKey: Self.speechLocaleKey) ?? "ko-KR"
        currentLocaleId = localeId
        // SFSpeechRecognizer와 권한 요청은 첫 사용 시까지 지연

        // Settings에서 micInputMode 변경 시 즉시 반영
        micModeObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .compactMap { _ in
                MicInputMode(rawValue: UserDefaults.standard.string(forKey: "micInputMode") ?? "tap")
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMode in
                self?.micMode = newMode
            }

        // 백그라운드 진입 시 세션을 해제하지 않으면 다른 앱의 미디어 재생이 계속 차단됨
        backgroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDidEnterBackground()
            }
    }

    private func handleDidEnterBackground() {
        guard didPrepare else { return }
        if audioEngine.isRunning {
            recognitionTask?.cancel()
            stopHandling()
        } else {
            deactivateAudioSession()
        }
    }

    /// 녹음 종료 후 반드시 세션을 해제해야 다른 앱의 오디오가 재개된다.
    /// (.record는 비혼합 카테고리라 활성 상태로 남으면 타 앱 미디어 재생을 막음)
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 첫 녹음 시작 전 한 번만 호출되는 무거운 초기화
    private func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: currentLocaleId))
        speechRecognizer?.delegate = self
        requestPermissions()
    }

    /// 뷰 등장 시 미리 호출해 첫 탭 렉을 방지합니다.
    /// SFSpeechRecognizer 초기화 + AVAudioSession 카테고리 사전 설정 (activate는 하지 않음)
    func warmUp() {
        prepareIfNeeded()
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setCategory(
                .record, mode: .measurement, options: .duckOthers
            )
        }
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    AVAudioApplication.requestRecordPermission { granted in
                        if !granted {
                            DispatchQueue.main.async {
                                self.errorMessage = L.voice.errorPermission
                                self.lastError = .permissionDenied
                            }
                        }
                    }
                case .denied, .restricted, .notDetermined:
                    self.errorMessage = L.voice.errorPermission
                    self.lastError = .permissionDenied
                @unknown default:
                    self.errorMessage = L.voice.errorRecognitionFailed
                }
            }
        }
    }
    
    func toggleListening() {
        prepareIfNeeded()
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
        // 앱 설정 언어와 인식 언어 동기화
        syncLocaleWithAppLanguage()
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            self.errorMessage = L.voice.errorRecognitionFailed
            self.lastError = .recognitionFailed
            return
        }
        
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
        audioFrameLock.withLock { audioFrameCount = 0 }
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
            self.errorMessage = L.voice.errorRecognitionFailed
            self.lastError = .recognitionFailed
            self.isListening = false
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            self.errorMessage = L.voice.errorRecognitionFailed
            self.lastError = .recognitionFailed
            self.isListening = false
            self.deactivateAudioSession()
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
                DispatchQueue.main.async {
                    self?.stopHandling()
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            // 오디오 스레드에서 실행됨 — 메인 스레드가 self.recognitionRequest를 nil로 바꾸는 것과
            // 경쟁하지 않도록 guard-let 로컬 상수를 사용 (종료된 request에 append는 무해)
            recognitionRequest.append(buffer)
            // 다운샘플링: 4프레임당 1회만 오디오 파워 계산
            guard let self else { return }
            let shouldUpdate: Bool = self.audioFrameLock.withLock {
                self.audioFrameCount += 1
                return self.audioFrameCount % Self.audioPowerSampleRate == 0
            }
            if shouldUpdate {
                self.updateAudioPower(buffer: buffer)
            }
        }
        
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
        } catch {
            self.errorMessage = L.voice.errorRecognitionFailed
            self.lastError = .recognitionFailed
            // 엔진이 시작되지 못했으므로 stopListening()은 no-op — 직접 정리해야 세션이 해제됨
            self.recognitionTask?.cancel()
            self.stopHandling()
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
        deactivateAudioSession()
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

    /// 앱의 현재 설정 언어에 맞춰 음성 인식기 로케일을 동기화합니다.
    private func syncLocaleWithAppLanguage() {
        let appLocale = AppLanguage.current.localeIdentifier
        if currentLocaleId != appLocale {
            currentLocaleId = appLocale
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: appLocale))
            speechRecognizer?.delegate = self
            print("🎙️ Speech Recognition Locale Synced: \(appLocale)")
        }
    }
}
