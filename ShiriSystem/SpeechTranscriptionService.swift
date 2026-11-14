import Foundation
import Speech
import AVFoundation
import Combine
import CoreMedia
import ShiriCore

@MainActor
final class LocalSpeechService: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var isPreparing = false
    @Published var canPrepareEnhancedResources = false
    @Published var resourceStatus: String?
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tapInstalled = false
    private var enhancedSession: AnyObject?
    private var resourceProgress: Progress?
    private var generation = UUID()
    private var interruption: AnyCancellable?
    init() {
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.error = "录音被系统中断，已识别文字需要核对。"
                    self.stop()
                }
            }
    }
    func checkEnhancedResources() async {
        let status = await CapabilityProvider.enhancedSpeech()
        guard status.isSupported else { return }
        canPrepareEnhancedResources = status == .needsResources
        resourceStatus = status == .ready ? "中文语音已准备好，识别时不会上传录音。" : "下载中文语音支持后，可使用增强识别。下载需要网络，录音不会上传。"
    }

    func prepareEnhancedResources() async {
        guard !isPreparing, !isRecording, #available(iOS 26.0, *),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { return }
        isPreparing = true; error = nil; defer { isPreparing = false; resourceProgress = nil }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                resourceProgress = installation.progress
                try await installation.downloadAndInstall()
            }
            await checkEnhancedResources()
        } catch { self.error = "语音准备未完成，请稍后重试或输入文字。" }
    }
    func start(requestPermissions: Bool = true) async {
        guard !isRecording, !isPreparing else { return }
        generation = UUID(); let currentGeneration = generation
        isPreparing = true; error = nil; defer { isPreparing = false }
        let microphone: Bool
        if requestPermissions {
            microphone = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        } else { microphone = AVAudioSession.sharedInstance().recordPermission == .granted }
        guard currentGeneration == generation else { return }
        guard microphone else { error = "麦克风权限未开启，你仍可以直接输入文字。"; return }
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if await AssetInventory.status(forModules: [transcriber]) == .installed {
                guard currentGeneration == generation else { return }
                do {
                    let session = EnhancedSpeechSession(transcriber: transcriber); enhancedSession = session
                    transcript = ""
                    try await session.start(onText: { [weak self] text in
                        guard self?.generation == currentGeneration else { return }; self?.transcript = text
                    }, onError: { [weak self] description in
                        guard self?.generation == currentGeneration else { return }; self?.error = description; self?.stop()
                    })
                    guard currentGeneration == generation else { session.cancel(); return }
                    isRecording = true; return
                } catch { self.error = error.localizedDescription; stop(); return }
            }
            await checkEnhancedResources()
        }
        let authorization: SFSpeechRecognizerAuthorizationStatus
        if requestPermissions {
            authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        } else { authorization = SFSpeechRecognizer.authorizationStatus() }
        guard currentGeneration == generation else { return }
        guard authorization == .authorized else { error = "语音识别权限未开启，你仍可以直接输入文字。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "此设备暂时无法识别中文语音，请输入文字。录音不会上传。"; return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true; request.taskHint = .dictation; self.request = request
            let node = engine.inputNode; let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw NSError(domain: "ShiriSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey:"麦克风暂时不可用，请稍后重试或输入文字。"]) }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; tapInstalled = true
            transcript = ""; error = nil; isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString; if result.isFinal { self.stop() } }
                    if let error, self.isRecording { self.error = error.localizedDescription; self.stop() }
                }
            }
            engine.prepare(); try engine.start()
        } catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        generation = UUID(); isRecording = false; engine.stop(); resourceProgress?.cancel()
        if #available(iOS 26.0, *), let session = enhancedSession as? EnhancedSpeechSession { session.cancel() }
        enhancedSession = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil; task?.finish(); task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func finish() async {
        if #available(iOS 26.0, *), let session = enhancedSession as? EnhancedSpeechSession {
            isRecording = false; isPreparing = true
            await session.finish(); enhancedSession = nil; isPreparing = false
        } else if isRecording {
            engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            request?.endAudio(); isPreparing = true
            // Keep accepting the recognizer's final result instead of invalidating it at button-up.
            for _ in 0..<30 {
                if !isRecording { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if isRecording { error = "录音末尾尚未确认，请先校对现有文字。" }
            stop(); isPreparing = false
        } else { stop() }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class EnhancedSpeechSession {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let engine = AVAudioEngine()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var tapped = false
    private var cancelled = false
    private var reportError: (@MainActor (String) -> Void)?
    init(transcriber: SpeechTranscriber) { self.transcriber = transcriber; analyzer = SpeechAnalyzer(modules: [transcriber]) }
    func start(onText: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void) async throws {
        reportError = onError
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "ShiriSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "当前音频设备暂不可用，可以输入文字或重新尝试。"])
        }
        try await analyzer.prepareToAnalyze(in: target)
        guard !cancelled else { throw CancellationError() }
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingOldest(64)) { input = $0 }
        let continuation = input!
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / source.sampleRate) + 1)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let inputBuffer = SpeechBufferOnce(buffer); var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                inputBuffer.take(status)
            }
            if let conversionError { Task { @MainActor in onError(conversionError.localizedDescription) }; return }
            if output.frameLength > 0 {
                if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                    Task { @MainActor in onError("这次录音处理未能跟上，请缩短输入后重试，或直接校对文字。") }
                }
            }
        }
        tapped = true
        resultsTask = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    if result.isFinal { finalized += text; onText(finalized) } else { onText(finalized + text) }
                }
            } catch { if !Task.isCancelled { onError(error.localizedDescription) } }
        }
        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { if !Task.isCancelled { onError(error.localizedDescription) } }
        }
        engine.prepare(); try engine.start()
    }
    private func stopInput() {
        engine.stop(); if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        input?.finish(); input = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func finish() async {
        stopInput()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { if !cancelled { reportError?("录音结束时未能完成转写，请先校对现有文字。") } }
        await resultsTask?.value; resultsTask = nil; analysisTask = nil
    }
    func cancel() {
        cancelled = true
        stopInput(); resultsTask?.cancel(); analysisTask?.cancel(); resultsTask = nil; analysisTask = nil
        Task { await analyzer.cancelAndFinishNow() }
    }
}

// AVAudioConverter consumes this buffer synchronously; the lock guarantees one delivery.
private final class SpeechBufferOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { status.pointee = .noDataNow; return nil }
        self.buffer = nil; status.pointee = .haveData; return buffer
    }
}
