import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text for the chat composer, so you can speak a note after a visit
/// instead of typing. Uses `requiresOnDeviceRecognition` to keep audio on the phone — nothing
/// is sent to a server, in keeping with the app's privacy promise.
@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var unavailable = false

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isSupported: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        guard await authorize(), let recognizer, recognizer.isAvailable else {
            unavailable = true
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // iOS 27 deprecates this for installTapOnBus:bufferSize:format:error:block:, but that
            // replacement is NS_REFINED_FOR_SWIFT with no clean Swift wrapper in the current beta
            // (only the raw __installTap with an NSError pointer). Keep this until the wrapper ships.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            unavailable = false

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
        } catch {
            unavailable = true
            stop()
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stop and clear — call after the composed note has been sent.
    func reset() {
        stop()
        transcript = ""
    }

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return speech && mic
    }
}
