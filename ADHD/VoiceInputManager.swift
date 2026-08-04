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
    @Published var silenceCountdown: Int = 0  // 0이면 비활성, 3→2→1→초안 확정
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
    private var isInputTapInstalled = false
    private var didEndRecognitionAudio = false
    private var activeRecognitionSessionID: UUID?
    private var draftFinalizationWorkItem: DispatchWorkItem?
    private static let draftFinalizationDeadline: TimeInterval = 2.0
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
        if activeRecognitionSessionID != nil {
            // 화면이 보이지 않는 즉시 마이크를 끄고 현재 전사문은 편집 초안으로 전달합니다.
            stopListening()
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
        if activeRecognitionSessionID != nil {
            stopListening()
        } else {
            startListening()
        }
    }
    
    func setMicMode(_ mode: MicInputMode) {
        micMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "micInputMode")
    }

    /// 로그아웃·계정 전환 때 이전 계정의 전사/초안을 publish하지 않고 즉시 폐기합니다.
    func discardAccountSensitiveState() {
        if let sessionID = activeRecognitionSessionID {
            abandonRecognitionSession(sessionID)
        } else {
            stopAudioCapture()
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            isListening = false
            isProcessing = false
        }
        draftFinalizationWorkItem?.cancel()
        draftFinalizationWorkItem = nil
        recognizedText = ""
        errorMessage = nil
        lastError = nil
        audioPower = 0
        recordingDuration = 0
        silenceCountdown = 0
        deactivateAudioSession()
    }

    func startListening() {
        // 앱 설정 언어와 인식 언어 동기화
        syncLocaleWithAppLanguage()
        guard !isProcessing else { return }
        guard activeRecognitionSessionID == nil else {
            // 논리 세션이 남아 있으면 오디오 엔진이 interruption으로 멈췄더라도
            // 새 녹음으로 초안을 덮지 않고 기존 세션을 먼저 확정합니다.
            stopListening()
            return
        }
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            self.errorMessage = L.voice.errorRecognitionFailed
            self.lastError = .recognitionFailed
            return
        }

        let sessionID = UUID()
        activeRecognitionSessionID = sessionID
        didEndRecognitionAudio = false
        
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
            abandonRecognitionSession(sessionID, error: .recognitionFailed)
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            abandonRecognitionSession(sessionID, error: .recognitionFailed)
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true // Real-time intermediate results
        
        let inputNode = audioEngine.inputNode
        
        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let transcription = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let didFail = error != nil

            DispatchQueue.main.async {
                guard let self, self.activeRecognitionSessionID == sessionID else { return }

                if let transcription {
                    self.recognizedText = transcription
                    self.lastSpeechTime = Date()
                    self.silenceCountdown = 0
                }

                if didFail || isFinal {
                    self.completeRecognitionSession(
                        sessionID,
                        error: didFail ? .recognitionFailed : nil
                    )
                }
            }
        }

        guard recognitionTask != nil else {
            abandonRecognitionSession(sessionID, error: .recognitionFailed)
            return
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
        isInputTapInstalled = true
        
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
        } catch {
            abandonRecognitionSession(sessionID, error: .recognitionFailed)
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
        guard let sessionID = activeRecognitionSessionID else { return }

        // 이미 final/error 또는 deadline을 기다리는 중이면 deadline을 다시 늘리지 않습니다.
        guard !isProcessing else {
            stopAudioCapture()
            return
        }

        stopAudioCapture()
        isListening = false
        isProcessing = true

        // final/error callback과 bounded deadline 중 먼저 도착한 결과를 세션당 한 번만 사용합니다.
        draftFinalizationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.completeRecognitionSession(sessionID)
        }
        draftFinalizationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.draftFinalizationDeadline,
            execute: workItem
        )
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
        if !didEndRecognitionAudio {
            recognitionRequest?.endAudio()
            didEndRecognitionAudio = true
        }
        audioPower = 0.0
        silenceCountdown = 0
        stopRecordingTimer()
        stopSilenceDetection()
        deactivateAudioSession()
    }

    private func completeRecognitionSession(_ sessionID: UUID, error: VoiceError? = nil) {
        guard activeRecognitionSessionID == sessionID else { return }

        draftFinalizationWorkItem?.cancel()
        draftFinalizationWorkItem = nil
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        isProcessing = true

        let finalizedText = recognizedText
        if finalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeRecognitionSessionID = nil
            isProcessing = false
            lastError = error ?? .emptyTranscription
            return
        }

        // 콜백이 초안을 동기적으로 반영할 때까지 session gate를 유지해
        // 늦은 이전 세션 결과가 새 녹음을 덮는 틈을 만들지 않습니다.
        if let onSpeechFinalized {
            onSpeechFinalized(finalizedText)
            recognizedText = ""
        }
        activeRecognitionSessionID = nil
        isProcessing = false
    }

    private func abandonRecognitionSession(_ sessionID: UUID, error: VoiceError? = nil) {
        guard activeRecognitionSessionID == sessionID else { return }

        draftFinalizationWorkItem?.cancel()
        draftFinalizationWorkItem = nil
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        activeRecognitionSessionID = nil
        isListening = false
        isProcessing = false
        if let error {
            errorMessage = error.message
            lastError = error
        }
    }

    private func removeInputTapIfNeeded() {
        guard isInputTapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        isInputTapInstalled = false
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
                        // 카운트다운 완료 → 편집 가능한 초안 확정
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
