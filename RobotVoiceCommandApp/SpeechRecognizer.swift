import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var authorizationStatusText = "Not requested"
    @Published var errorMessage: String?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasMicrophonePermission = false
    private var hasSpeechPermission = false

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.hasSpeechPermission = status == .authorized
                self.authorizationStatusText = Self.text(for: status)

                if status != .authorized {
                    self.errorMessage = "Speech recognition permission denied. Enable it in iOS Settings."
                }
            }
        }

        requestMicrophonePermission()
    }

    func startRecording() {
        errorMessage = nil

        guard !isRecording else { return }
        guard hasSpeechPermission else {
            errorMessage = "Speech recognition permission denied. Enable it in iOS Settings."
            return
        }
        guard hasMicrophonePermission else {
            errorMessage = "Microphone permission denied. Enable it in iOS Settings."
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer is unavailable right now."
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        do {
            try configureAudioSession()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            if speechRecognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
                request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            recognitionRequest = request
            isRecording = true

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let result {
                        self.transcript = result.bestTranscription.formattedString

                        if result.isFinal {
                            self.stopRecording()
                        }
                    }

                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.stopRecording()
                    }
                }
            }
        } catch {
            errorMessage = "Could not start speech recognition: \(error.localizedDescription)"
            stopRecording()
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Could not deactivate microphone session: \(error.localizedDescription)"
        }
    }

    func resetTranscript() {
        transcript = ""
        errorMessage = nil
    }

    private func requestMicrophonePermission() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    self?.updateMicrophonePermission(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    self?.updateMicrophonePermission(granted)
                }
            }
        }
    }

    private func updateMicrophonePermission(_ granted: Bool) {
        hasMicrophonePermission = granted

        if !granted {
            errorMessage = "Microphone permission denied. Enable it in iOS Settings."
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private static func text(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }
}
