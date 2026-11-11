import AppKit
import AVFoundation
import ShazamKit
import Combine

/// Music recognition with Apple's ShazamKit (public API, macOS 12+).
///
/// - Listens to the chosen source for at most 30 seconds. System audio is
///   available on macOS 14.2 and later.
/// - Audio buffers go straight into `SHSession`; nothing is recorded, stored
///   or uploaded by Notch Island. ShazamKit sends audio *signatures* to Apple
///   to find a match (needs internet).
/// - Microphone permission is requested at that moment; system-audio capture
///   triggers macOS's own "System Audio Recording" prompt when first used.
/// - Results come only from ShazamKit; an error is never shown as "no match".
@MainActor
final class ShazamRecognizer: NSObject, ObservableObject {
    struct Song: Equatable {
        var title: String
        var artist: String
        var artworkURL: URL?
        var appleMusicURL: URL?
        var webURL: URL?
    }

    enum Source { case microphone, systemAudio }

    static var supportsSystemAudio: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    enum Failure: Equatable {
        case microphoneDenied
        /// No usable audio source could be started.
        case noAudioSource
        case network
        /// ShazamKit error code. 202 is `SHErrorCodeMatchAttemptFailed`, which
        /// SHError.h documents as "a Shazam Music catalog server issue prevents
        /// finding a match". The code alone does not say *why* (server outage,
        /// missing ShazamKit App Service on the App ID, …) — never claim a cause.
        case service(Int)
    }

    /// SHError.h / SHSession.h: catalog-communication errors may be retried.
    nonisolated static let retryableServiceCodes: Set<Int> = [
        SHError.Code.matchAttemptFailed.rawValue,   // 202
        SHError.Code.internalError.rawValue,        // 500
        SHError.Code.mediaItemFetchFailed.rawValue, // 600
    ]

    /// Apple's own Control Center "Recognize Music" guide (support article 118570).
    nonisolated static func recognizeMusicGuideURL(_ language: AppLanguage) -> URL {
        let region: String
        switch language.resolved {
        case .traditionalChinese: region = "zh-tw"
        case .simplifiedChinese: region = "zh-cn"
        default: region = "en-us"
        }
        return URL(string: "https://support.apple.com/\(region)/118570")!
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case listening(source: Source)
        case matched(Song)
        case noMatch
        case failed(Failure)
        case cancelled
    }

    enum ShortcutPhase: Equatable {
        case idle, running, finished, failed
        /// `shortcuts` reported "Couldn’t find shortcut" for the typed name.
        case notFound
        /// Stopped by the user from the island, or after `shortcutTimeout`.
        case stopped, timedOut
        case result(String)
    }

    /// A Shazam shortcut normally ends within ~15 s; never leave one running unseen.
    static let shortcutTimeout: TimeInterval = 90
    private var shortcutProcess: Process?
    private var shortcutRun = 0

    static let timeout: TimeInterval = 30

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    /// The catalog reported error 202 during this attempt; still retrying until the time limit.
    @Published private(set) var catalogErrorWhileListening = false
    @Published private(set) var shortcutPhase: ShortcutPhase = .idle

    private var session: SHSession?
    private let audioInput = MusicRecognitionAudioInput()
    private var timeoutTask: Task<Void, Never>?
    private var lastError: Failure?
    private var attempt = 0

    var isListening: Bool {
        if case .listening = phase { return true }
        return phase == .preparing
    }

    /// User explicitly selected a source in the Shazam panel.
    func start(source: Source) {
        guard !isListening else { return }
        attempt += 1
        let current = attempt
        phase = .preparing
        lastError = nil
        catalogErrorWhileListening = false
        Task { [weak self] in
            let micAllowed = source == .microphone ? await Self.microphoneAccess() : false
            guard let self, self.attempt == current, self.phase == .preparing else { return }
            let box = SessionBox(self.makeSession())
            let started = (source != .microphone || micAllowed) && self.audioInput.start(source,
                microphone: { buffer, time in
                    box.session.matchStreamingBuffer(buffer, at: time)
                },
                systemAudio: { samples, rate in
                    if let buffer = ShazamRecognizer.monoBuffer(samples, sampleRate: rate) {
                        box.session.matchStreamingBuffer(buffer, at: nil)
                    }
                })
            guard started else {
                self.stopAll()
                self.phase = .failed(source == .microphone && !micAllowed ? .microphoneDenied : .noAudioSource)
                return
            }
            self.phase = .listening(source: source)
            self.startedAt = Date()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeout))
                guard !Task.isCancelled else { return }
                self?.finishWithoutMatch(attempt: current)
            }
        }
    }

    func cancel() {
        guard isListening else { return }
        attempt += 1
        stopAll()
        phase = .cancelled
    }

    func reset() {
        if isListening { cancel() }
        phase = .idle
    }

    func clearShortcutResult() {
        if shortcutPhase != .running { shortcutPhase = .idle }
    }

    /// Run only the shortcut the user explicitly named. The shortcut and Apple
    /// handle recognition. No audio, clipboard contents or files are passed in.
    func runShortcut(named name: String) {
        guard shortcutPhase != .running, !isListening else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", "--output-type", "public.utf8-plain-text", "--", name]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Only read to tell "no such shortcut" apart; never stored or logged.
        process.standardError = errors
        shortcutRun += 1
        let run = shortcutRun
        do {
            try process.run()
            shortcutProcess = process
            shortcutPhase = .running
        } catch {
            shortcutPhase = .failed
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shortcutTimeout) { [weak self] in
            guard let self, self.shortcutRun == run, self.shortcutPhase == .running else { return }
            self.stopShortcut(as: .timedOut)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Drain both pipes at once so neither can fill up and block the shortcut.
            final class Box: @unchecked Sendable { var data = Data() } // written once, read after `wait()`
            let errorText = Box()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorText.data = Self.readBounded(errors.fileHandleForReading, limit: 2048)
                group.leave()
            }
            let text = Self.readBounded(output.fileHandleForReading, limit: 1024)
            group.wait()
            process.waitUntilExit()
            let status = Self.shortcutOutcome(status: process.terminationStatus,
                                              reason: process.terminationReason, output: text, errorOutput: errorText.data)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shortcutRun == run else { return }
                self.shortcutProcess = nil
                // A stop/timeout already set the phase; keep it.
                if self.shortcutPhase == .running { self.shortcutPhase = status }
            }
        }
    }

    /// The user's "Stop" in the island (also used by the time limit).
    func stopShortcut(as phase: ShortcutPhase = .stopped) {
        guard shortcutPhase == .running else { return }
        shortcutPhase = phase
        if let process = shortcutProcess, process.isRunning { process.terminate() }
        shortcutProcess = nil
    }

    private nonisolated static func readBounded(_ handle: FileHandle, limit: Int) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
            if data.count < limit { data.append(contentsOf: chunk.prefix(limit - data.count)) }
        }
        return data
    }

    /// Exact phrase `/usr/bin/shortcuts` prints on macOS 27 for an unknown name
    /// ("Error: The operation couldn’t be completed. Couldn’t find shortcut").
    nonisolated static func isShortcutNotFound(_ errorOutput: Data) -> Bool {
        let text = String(decoding: errorOutput, as: UTF8.self).replacingOccurrences(of: "’", with: "'").lowercased()
        return text.contains("couldn't find shortcut")
    }

    nonisolated static func shortcutOutcome(status: Int32, reason: Process.TerminationReason, output: Data,
                                            errorOutput: Data = Data()) -> ShortcutPhase {
        if reason == .exit, status != 0, isShortcutNotFound(errorOutput) { return .notFound }
        guard reason == .exit, status == 0 else { return .failed }
        let text = String(decoding: output, as: UTF8.self).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let result = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? .finished : .result(result)
    }

    // MARK: Pure outcome rule (tests)

    /// After the time limit: an error seen during matching is reported as an
    /// error (not "no match"); otherwise "no match".
    nonisolated static func outcomeAtTimeout(lastError: Failure?) -> Phase {
        lastError.map { .failed($0) } ?? .noMatch
    }

    nonisolated static func failure(for error: Error) -> Failure? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .network }
        if ns.domain == SHErrorDomain {
            // Normal while streaming: discontinuities, silence (200, "most common
            // cause is silent audio input") and too-short signatures (201).
            // They mean "no usable audio yet", not a failure → keep listening.
            if [SHError.Code.audioDiscontinuity, .signatureInvalid, .signatureDurationInvalid]
                .map(\.rawValue).contains(ns.code) { return nil }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain { return .network }
            return .service(ns.code)
        }
        return .service(ns.code)
    }

    /// Mono Float32 PCM buffer for ShazamKit from raw samples.
    nonisolated static func monoBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: Sources

    nonisolated static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeSession() -> SHSession {
        let session = SHSession()
        session.delegate = self
        self.session = session
        return session
    }

    private func stopAll() {
        timeoutTask?.cancel(); timeoutTask = nil
        audioInput.stop()
        session?.delegate = nil
        session = nil
        startedAt = nil
    }

    private func finishWithoutMatch(attempt current: Int) {
        guard attempt == current, isListening else { return }
        stopAll()
        phase = Self.outcomeAtTimeout(lastError: lastError)
    }

    private func found(_ song: Song, session: SHSession) {
        guard isListening, self.session === session else { return }
        attempt += 1
        stopAll()
        phase = .matched(song)
    }

    private func noteError(_ error: Error?, session: SHSession) {
        guard isListening, self.session === session,
              let error, let failure = Self.failure(for: error) else { return }
        lastError = failure
        if failure == .service(SHError.Code.matchAttemptFailed.rawValue) { catalogErrorWhileListening = true }
        if Self.stopsImmediately(failure) {
            attempt += 1
            stopAll()
            phase = .failed(failure)
        }
    }

    /// Network errors and retryable catalog errors (202/500/600, per SHSession.h
    /// "you can retry the match if the error indicates an issue in communicating
    /// with the catalog server") keep listening until the 30 s limit and are then
    /// reported as the error. Other ShazamKit errors (bad audio format, custom
    /// catalog, unknown codes) stop at once.
    /// (A one-off synthetic-audio test on macOS 27.0.1 with ad-hoc builds got 202;
    /// that does not establish the cause, so 202 is not treated as permanent.)
    nonisolated static func stopsImmediately(_ failure: Failure) -> Bool {
        if case .service(let code) = failure { return !retryableServiceCodes.contains(code) }
        return false
    }
}

/// An explicitly selected input. The consumer determines how long to listen
/// and where buffers go. Both recognition paths stop their own input on cancel.
@MainActor
final class MusicRecognitionAudioInput {
    private var engine: AVAudioEngine?
    private var tap: AnyObject?

    func start(_ source: ShazamRecognizer.Source,
               microphone: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
               systemAudio: @escaping @Sendable ([Float], Double) -> Void) -> Bool {
        switch source {
        case .microphone:
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return false }
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: microphone)
            do {
                try engine.start()
                self.engine = engine
                return true
            } catch {
                input.removeTap(onBus: 0)
                return false
            }
        case .systemAudio:
            guard #available(macOS 14.2, *) else { return false }
            let instance = SystemAudioTap()
            do {
                try instance.start(onLevels: { _ in }, onSamples: systemAudio)
                tap = instance
                return true
            } catch {
                instance.stop()
                return false
            }
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
    }
}

extension ShazamRecognizer: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        let song = Song(title: item.title ?? "", artist: item.artist ?? "", artworkURL: item.artworkURL,
                        appleMusicURL: item.appleMusicURL, webURL: item.webURL)
        guard !song.title.isEmpty else { return }
        Task { @MainActor [weak self] in self?.found(song, session: session) }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        Task { @MainActor [weak self] in self?.noteError(error, session: session) }
    }
}

/// `SHSession.matchStreamingBuffer` is meant to be called from audio threads.
final class SessionBox: @unchecked Sendable {
    let session: SHSession
    init(_ session: SHSession) { self.session = session }
}
