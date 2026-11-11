import AppKit
import AVFoundation
import SwiftUI

// MARK: - Shared helpers

/// 16-bit mono PCM WAV (no length or silence checks; callers decide).
enum PCMWave {
    static func encode(_ samples: [Float], rate: Int) -> Data {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + byteCount)
        data.append(contentsOf: "RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))      // PCM fmt chunk length
        append(UInt16(1))       // PCM
        append(UInt16(1))       // mono
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))       // bytes per frame
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(byteCount))
        let pcm = samples.map { sample -> Int16 in
            guard sample.isFinite else { return 0 }
            return Int16((min(1, max(-1, sample)) * Float(Int16.max)).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

/// Never follow a redirect: the request (and the audio in it) stays with the host it was built for.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Song Finder protocol (pure, testable)

/// Song Finder (https://songfinder.dev): free music recognition, no API key, no account.
///
/// Checked 2026-11-11 against Song Finder's own MIT-licensed clients — npm `songfinder`
/// 0.1.0 (`dist/client.js`, registry shasum 1f0cdf02…) and `songfinder-mcp` 0.1.0
/// (`dist/api.js`) — plus its official `identify-song` Agent Skill, its Developers page,
/// Privacy Policy and Terms (both "last updated 2026-08-25"):
/// - `POST https://songfinder.dev/api/music/recognize`, multipart `file` (wav accepted,
///   10 MB server cap) and `source`, header `X-SongFinder-Client`.
/// - Every answer is the envelope `{ code, message, data }`. A non-zero `code` is a failure
///   regardless of the HTTP status; HTTP 429 is the per-IP rate limit.
/// - `data.matched` (Bool) with optional `title`, `artist`, `album`, … ("fields vary by
///   engine"). The server budgets 100 s for its engine chain; the official clients wait 120 s.
/// - Privacy Policy: the clip is sent to the configured recognition services (currently
///   ACRCloud, AudioTag and Shazam; AudD disabled) and not retained after the request.
enum SongFinderService {
    static let endpoint = URL(string: "https://songfinder.dev/api/music/recognize")!
    static let homeURL = URL(string: "https://songfinder.dev/")!
    static let privacyURL = URL(string: "https://songfinder.dev/privacy-policy")!
    static let termsURL = URL(string: "https://songfinder.dev/terms-of-service")!
    /// Clients without a browser (no Turnstile check) identify themselves with this header.
    /// `cli` is the value Song Finder's documentation gives plain HTTP/curl callers. The
    /// server's list of accepted values is not public: a refusal is reported as a refusal.
    static let clientHeader = "X-SongFinder-Client"
    static let clientValue = "cli"
    static let maxUploadBytes = 10 * 1024 * 1024
    /// One clip per press: about 12 s, resampled to 16 kHz mono (≈ 384 KB WAV).
    static let captureSeconds = 12
    static let minimumSeconds = 3
    static let uploadRate = 16_000
    static let requestTimeout: TimeInterval = 120
    /// Bump when the disclosure changes materially so the user is asked again.
    static let consentVersion = 1
    static let consentKey = "NotchIsland.songFinder.consentVersion"

    struct Song: Equatable {
        var title: String
        var artist: String
        var album: String?
    }

    enum Outcome: Equatable {
        case matched(Song)
        /// `code` 0 and `matched: false` — the only answer shown as "not found".
        case noMatch
        /// HTTP 429.
        case rateLimited
        /// HTTP 401/403: Song Finder would not accept this request or client.
        case refused(Int)
        /// HTTP 413.
        case tooLarge
        /// HTTP 5xx.
        case serverError(Int)
        /// Non-zero `code` on another status; Song Finder's message (sanitized), if any.
        case serviceError(String?, Int)
        /// Not the documented envelope, or a "match" without title/artist.
        case badResponse(Int)
    }

    enum TransportFailure: Equatable {
        case offline, timeout, secureConnection
        case network(Int)
    }

    private struct Head: Decodable { let code: Int; let message: String? }
    private struct Body: Decodable { let data: Track? }
    private struct Track: Decodable {
        let matched: Bool
        let title: String?
        let artist: String?
        let album: String?
    }

    static func parse(data: Data, httpStatus: Int) -> Outcome {
        if httpStatus == 429 { return .rateLimited }
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else {
            return statusOutcome(httpStatus) ?? .badResponse(httpStatus)
        }
        if head.code != 0 {
            return statusOutcome(httpStatus) ?? .serviceError(sanitized(head.message), httpStatus)
        }
        guard (200..<300).contains(httpStatus),
              let body = try? JSONDecoder().decode(Body.self, from: data), let track = body.data else {
            return .badResponse(httpStatus)
        }
        guard track.matched else { return .noMatch }
        let title = (track.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return .badResponse(httpStatus) }
        let album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .matched(Song(title: String(title.prefix(300)), artist: String(artist.prefix(300)),
                             album: album.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }))
    }

    private static func statusOutcome(_ status: Int) -> Outcome? {
        switch status {
        case 401, 403: return .refused(status)
        case 413: return .tooLarge
        case 500...599: return .serverError(status)
        default: return nil
        }
    }

    /// Server text is shown as data: control characters removed, length capped.
    static func sanitized(_ message: String?) -> String? {
        guard let message else { return nil }
        let scalars = message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(160))
    }

    /// nil for a cancelled request (the user stopped it).
    static func transportFailure(_ error: Error) -> TransportFailure? {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .network(ns.code) }
        switch URLError.Code(rawValue: ns.code) {
        case .cancelled: return nil
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .offline
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnection
        default: return .network(ns.code)
        }
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "NotchIsland/\(version) (+https://github.com/LeoFeng0816/Notch-Island)"
    }

    static func makeRequest(wav: Data, boundary: String = "NotchIsland-\(UUID().uuidString)") -> URLRequest {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"source\"\r\n\r\n\(clientValue)\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(clientValue, forHTTPHeaderField: clientHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body
        return request
    }

    static let shared = makeSession()

    /// Ephemeral: no cookies, no cache, no redirects.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout + 10
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    // MARK: Result actions

    /// What "Copy" puts on the pasteboard.
    static func copyText(_ song: Song) -> String { "\(song.artist) - \(song.title)" }

    /// Google Search prefilled with "artist title" (strictly percent-encoded).
    static func googleSearchURL(_ song: Song) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = "\(song.artist) \(song.title)".addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "https://www.google.com/search?q=\(query)")!
    }
}

// MARK: - Audio preparation (pure, testable)

enum SongFinderAudio {
    struct Prepared: Equatable {
        var wav: Data?
        var systemHasSound: Bool
        var microphoneHasSound: Bool
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var total: Float = 0
        for value in samples where value.isFinite { total += value * value }
        return (total / Float(samples.count)).squareRoot()
    }

    /// At least 3 s that is not silence (exact zeros, or a level below about −66 dBFS).
    static func hasSound(_ samples: [Float], rate: Int = SongFinderService.uploadRate) -> Bool {
        guard samples.count >= SongFinderService.minimumSeconds * rate else { return false }
        return samples.contains(where: { $0.isFinite && abs($0) >= 0.001 }) && rms(samples) >= 0.0005
    }

    /// Band-limited sample-rate conversion (AVAudioConverter).
    static func resample(_ samples: [Float], from rate: Int, to target: Int = SongFinderService.uploadRate) -> [Float] {
        guard rate > 0, target > 0, !samples.isEmpty else { return [] }
        if rate == target { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(target), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = ShazamRecognizer.monoBuffer(samples, sampleRate: Double(rate)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * Double(target) / Double(rate)) + 4096)
        else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Each included source is brought to the same loudness; when both have sound the
    /// microphone is mixed 6 dB under the Mac audio (room noise should not mask a clean
    /// copy of the song). Empty arrays mean "not included".
    static func mix(system: [Float], microphone: [Float]) -> [Float] {
        func normalized(_ samples: [Float]) -> [Float] {
            let level = rms(samples)
            guard level > 0 else { return samples }
            let gain = min(30, 0.1 / level)
            return samples.map { $0.isFinite ? $0 * gain : 0 }
        }
        let a = system.isEmpty ? [] : normalized(system)
        let b = microphone.isEmpty ? [] : normalized(microphone)
        let micWeight: Float = a.isEmpty ? 1 : 0.5
        let count = max(a.count, b.count)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = (i < a.count ? a[i] : 0) + micWeight * (i < b.count ? b[i] : 0)
        }
        let peak = out.reduce(0) { max($0, abs($1)) }
        if peak > 0.98 { let scale = 0.98 / peak; for i in 0..<count { out[i] *= scale } }
        return out
    }

    static func prepare(system: (samples: [Float], rate: Int)?, microphone: (samples: [Float], rate: Int)?) -> Prepared {
        let rate = SongFinderService.uploadRate
        let sys = system.map { resample($0.samples, from: $0.rate, to: rate) } ?? []
        let mic = microphone.map { resample($0.samples, from: $0.rate, to: rate) } ?? []
        let sysSound = hasSound(sys, rate: rate)
        let micSound = hasSound(mic, rate: rate)
        let mixed = Array(mix(system: sysSound ? sys : [], microphone: micSound ? mic : [])
            .prefix(SongFinderService.captureSeconds * rate))
        let wav = mixed.isEmpty ? nil : PCMWave.encode(mixed, rate: rate)
        return Prepared(wav: wav.flatMap { $0.count <= SongFinderService.maxUploadBytes ? $0 : nil },
                        systemHasSound: sysSound, microphoneHasSound: micSound)
    }
}

// MARK: - Recognition flow

/// Nothing happens until the user presses Music Recognition. The first time, the island
/// shows what will be sent where and records only after "Agree and Start". Then about
/// 12 s of the microphone and the Mac's sound output (each only if available and allowed)
/// is held in memory, mixed into one clip, sent once to Song Finder, and dropped.
@MainActor
final class SongFinderRecognition: ObservableObject {
    enum SourceStatus: Equatable {
        case off, starting, recording
        /// Had sound and is part of the uploaded clip.
        case included
        /// Started but only silence arrived (for Mac audio: nothing playing, or not allowed).
        case silent
        /// Microphone permission is off for Notch Island.
        case denied
        /// Could not be started (no device, capture setup failed).
        case unavailable
        /// Mac audio capture needs macOS 14.2.
        case unsupported
    }

    struct Sources: Equatable {
        var systemAudio: SourceStatus = .off
        var microphone: SourceStatus = .off
        var included: [ShazamRecognizer.Source] {
            (systemAudio == .included ? [.systemAudio] : []) + (microphone == .included ? [.microphone] : [])
        }
    }

    enum Phase: Equatable {
        case idle
        /// Song Finder isn't the method chosen in Settings.
        case notSelected
        case needsConsent
        case preparing, listening, sending
        case cancelled(afterSending: Bool)
        /// Nothing usable was captured; nothing was uploaded.
        case noAudio
        case finished(SongFinderService.Outcome)
        case transport(SongFinderService.TransportFailure)

        var busy: Bool { self == .preparing || self == .listening || self == .sending }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sources = Sources()
    @Published private(set) var listeningStartedAt: Date?
    /// When the last press produced an answer or error (keeps the island up briefly to show it).
    private(set) var resultShownAt: Date?
    static let resultHold: TimeInterval = 8

    private let defaults: UserDefaults
    private let session: URLSession
    private let audio: AudDAudioSource
    private let systemAudioSupported: Bool
    let listenDuration: Duration
    private let microphoneAccess: @Sendable () async -> Bool
    private var clips: [AudDClip] = []
    private var task: Task<Void, Never>?
    private var run = 0

    init(defaults: UserDefaults = .standard,
         session: URLSession = SongFinderService.shared,
         audio: AudDAudioSource? = nil,
         systemAudioSupported: Bool = ShazamRecognizer.supportsSystemAudio,
         listenDuration: Duration = .seconds(SongFinderService.captureSeconds),
         microphoneAccess: @escaping @Sendable () async -> Bool = { await ShazamRecognizer.microphoneAccess() }) {
        self.defaults = defaults
        self.session = session
        self.audio = audio ?? LiveAudDAudioSource()
        self.systemAudioSupported = systemAudioSupported
        self.listenDuration = listenDuration
        self.microphoneAccess = microphoneAccess
    }

    var consented: Bool { defaults.integer(forKey: SongFinderService.consentKey) >= SongFinderService.consentVersion }

    /// Song Finder is the default: also when nothing (or an unknown value) is stored.
    var selected: Bool {
        MusicRecognitionMode.resolve(defaults.string(forKey: MusicRecognitionMode.defaultsKey) ?? "") == .songFinder
    }

    func giveConsent() {
        objectWillChange.send()
        defaults.set(SongFinderService.consentVersion, forKey: SongFinderService.consentKey)
    }

    func withdrawConsent() {
        cancel()
        objectWillChange.send()
        defaults.set(0, forKey: SongFinderService.consentKey)
        if !phase.busy { phase = .idle }
    }

    /// Only ever called from the user's press (quick action, Agree and Start, Try Again).
    func start() {
        guard !phase.busy else { return }
        resultShownAt = nil
        guard selected else { phase = .notSelected; return }
        guard consented else { phase = .needsConsent; return }
        run += 1
        let current = run
        phase = .preparing
        sources = Sources(systemAudio: systemAudioSupported ? .starting : .unsupported, microphone: .starting)
        task = Task { [weak self] in
            guard let self else { return }
            // Microphone permission (macOS asks the first time; this follows the user's press).
            let micAllowed = await self.microphoneAccess()
            guard !Task.isCancelled, self.run == current else { return }
            let systemClip = AudDClip(limitSeconds: SongFinderService.captureSeconds)
            let micClip = AudDClip(limitSeconds: SongFinderService.captureSeconds)
            self.clips = [systemClip, micClip]
            if self.systemAudioSupported {
                self.sources.systemAudio = self.audio.begin(.systemAudio, into: systemClip) ? .recording : .unavailable
            }
            if micAllowed {
                self.sources.microphone = self.audio.begin(.microphone, into: micClip) ? .recording : .unavailable
            } else {
                self.sources.microphone = .denied
            }
            guard self.sources.systemAudio == .recording || self.sources.microphone == .recording else {
                self.audio.end()
                self.dropClips()
                self.phase = .noAudio
                return
            }
            self.phase = .listening
            self.listeningStartedAt = Date()
            do { try await Task.sleep(for: self.listenDuration) } catch { return } // cancel() cleans up
            guard !Task.isCancelled, self.run == current else { return }
            self.audio.end()
            self.listeningStartedAt = nil
            let systemAudio = self.sources.systemAudio == .recording ? systemClip.finish() : nil
            let microphone = self.sources.microphone == .recording ? micClip.finish() : nil
            self.dropClips()
            let prepared = await Task.detached(priority: .userInitiated) {
                SongFinderAudio.prepare(system: systemAudio, microphone: microphone)
            }.value
            guard !Task.isCancelled, self.run == current else { return }
            if self.sources.systemAudio == .recording { self.sources.systemAudio = prepared.systemHasSound ? .included : .silent }
            if self.sources.microphone == .recording { self.sources.microphone = prepared.microphoneHasSound ? .included : .silent }
            guard let wav = prepared.wav else { self.phase = .noAudio; self.resultShownAt = Date(); return }
            // One upload, then the audio is gone.
            self.phase = .sending
            do {
                let (data, response) = try await self.session.data(for: SongFinderService.makeRequest(wav: wav))
                guard !Task.isCancelled, self.run == current else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.phase = .finished(SongFinderService.parse(data: data, httpStatus: status))
                self.resultShownAt = Date()
            } catch {
                guard !Task.isCancelled, self.run == current else { return }
                if let failure = SongFinderService.transportFailure(error) { self.phase = .transport(failure) }
                else { self.phase = .cancelled(afterSending: true) }
                self.resultShownAt = Date()
            }
        }
    }

    /// Busy, or a result arrived in the last few seconds: the island stays open so the
    /// recording is visible and its outcome isn't missed when the pointer has moved away.
    func keepsIslandOpen(now: Date = Date()) -> Bool {
        phase.busy || resultShownAt.map { now.timeIntervalSince($0) < Self.resultHold } == true
    }

    private func dropClips() {
        for clip in clips { clip.discard() }
        clips = []
    }

    /// Stops capture, cancels a pending request and discards the audio.
    func cancel() {
        guard phase.busy else { return }
        let afterSending = phase == .sending
        run += 1
        task?.cancel()
        task = nil
        dropClips()
        audio.end()
        listeningStartedAt = nil
        resultShownAt = nil
        phase = .cancelled(afterSending: afterSending)
    }

    func reset() {
        if phase.busy { cancel() }
        phase = .idle
    }

    /// For tests: clips currently held in memory.
    var heldClips: [AudDClip] { clips }
}

// MARK: - Island page

struct SongFinderPage: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var recognition: SongFinderRecognition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SubpageHeader(title: lang.t(.qaShazam), closeLabel: lang.t(.close), close: close) {
                Text("Song Finder").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if recognition.phase != .needsConsent {
                Text(lang.t(.sfReminder)).font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .onDisappear { recognition.cancel() }
    }

    private func close() {
        recognition.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.subpage = .none }
    }

    @ViewBuilder private var content: some View {
        switch recognition.phase {
        case .needsConsent:
            VStack(alignment: .leading, spacing: 5) {
                Text(lang.t(.sfConsentTitle)).font(.system(size: 12, weight: .semibold))
                Text(lang.t(.sfConsentBody)).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(7).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(lang.t(.sfAgreeStart)) {
                        recognition.giveConsent()
                        recognition.start()
                    }.buttonStyle(PillStyle(highlighted: true))
                    Button(lang.t(.sfPrivacyPolicy)) { NSWorkspace.shared.open(SongFinderService.privacyURL) }.buttonStyle(PillStyle())
                    Button(lang.t(.cancel), action: close).buttonStyle(PillStyle())
                }
            }
        case .preparing, .listening, .sending:
            HStack(alignment: .top, spacing: 14) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Image(systemName: recognition.phase == .sending ? "arrow.up.circle.fill" : "waveform.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color(hex: 0x0A84FF))
                        .opacity(reduceMotion ? 1 : 0.75 + 0.25 * sin(t * 4))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(busyTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    sourceRows
                    if recognition.phase == .listening {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            let total = Double(SongFinderService.captureSeconds)
                            let elapsed = recognition.listeningStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                            let fraction = min(max(elapsed / total, 0), 1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.15))
                                Capsule().fill(Color(hex: 0x0A84FF)).frame(width: 180 * fraction)
                            }
                            .frame(width: 180, height: 4)
                            .accessibilityElement()
                            .accessibilityLabel(busyTitle)
                            .accessibilityValue("\(Int((fraction * 100).rounded()))%")
                        }
                    } else if recognition.phase == .sending {
                        ProgressView().controlSize(.small)
                    }
                    Button(lang.t(.cancel)) { recognition.cancel() }.buttonStyle(PillStyle())
                }
            }
        case .finished(.matched(let song)):
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                Text(song.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).textSelection(.enabled)
                if let album = song.album {
                    Text(album).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.open(SongFinderService.googleSearchURL(song))
                    } label: { Label(lang.t(.sfGoogle), systemImage: "magnifyingglass") }
                        .buttonStyle(PillStyle())
                        .help(lang.t(.sfGoogleHelp))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SongFinderService.copyText(song), forType: .string)
                        model.showToast(IslandToast(symbol: "doc.on.doc.fill", text: lang.t(.toastCopied), style: .success))
                    } label: { Label(lang.t(.shazamCopy), systemImage: "doc.on.doc") }
                        .buttonStyle(PillStyle())
                        .help(lang.t(.sfCopyHelp))
                    againButton
                }
                .padding(.top, 2)
                Text(lang.t(.sfIdentifiedBy) + " · " + sentText).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                Label(message, systemImage: isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(isProblem ? .yellow : .white)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                if recognition.phase != .idle && recognition.phase != .notSelected { sourceRows }
                HStack(spacing: 6) {
                    if recognition.phase == .notSelected {
                        Button(lang.t(.settingsMenu)) { model.onOpenSettings?() }.buttonStyle(PillStyle())
                    } else {
                        againButton
                    }
                    if recognition.sources.microphone == .denied {
                        Button(lang.t(.sfOpenMicSettings)) { SystemSettingsLink.open(.microphone) }.buttonStyle(PillStyle())
                    }
                    if recognition.sources.systemAudio == .silent || recognition.sources.systemAudio == .unavailable {
                        Button(lang.t(.sfOpenAudioSettings)) { SystemSettingsLink.open(.audioCapture) }.buttonStyle(PillStyle())
                    }
                }
            }
        }
    }

    private var againButton: some View {
        Button(lang.t(recognition.phase == .idle ? .start : .sfTryAgain)) { recognition.start() }.buttonStyle(PillStyle())
    }

    private var busyTitle: String {
        switch recognition.phase {
        case .preparing: return lang.t(.sfPreparing)
        case .sending: return lang.t(.sfSending)
        default: return lang.t(.sfListening, String(SongFinderService.captureSeconds))
        }
    }

    private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(lang.t(.sfSourceLine, lang.t(.sfSourceMac), statusText(recognition.sources.systemAudio, mac: true)))
            Text(lang.t(.sfSourceLine, lang.t(.sfSourceMic), statusText(recognition.sources.microphone, mac: false)))
        }
        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
    }

    private func statusText(_ status: SongFinderRecognition.SourceStatus, mac: Bool) -> String {
        switch status {
        case .off, .starting: return lang.t(.sfStatusStarting)
        case .recording: return lang.t(.sfStatusRecording)
        case .included: return lang.t(.sfStatusIncluded)
        case .silent: return lang.t(mac ? .sfStatusSilentMac : .sfStatusSilent)
        case .denied: return lang.t(.sfStatusDenied)
        case .unavailable: return lang.t(.sfStatusUnavailable)
        case .unsupported: return lang.t(.sfStatusUnsupported)
        }
    }

    private var sentText: String {
        let names = recognition.sources.included.map { lang.t($0 == .systemAudio ? .sfSourceMac : .sfSourceMic) }
        return lang.t(.sfSent, names.joined(separator: " + "))
    }

    private var isProblem: Bool {
        switch recognition.phase {
        case .idle, .finished(.noMatch), .cancelled: return false
        default: return true
        }
    }

    private var message: String {
        switch recognition.phase {
        case .idle: return lang.t(.sfIdleHint)
        case .notSelected: return lang.t(.sfNotSelected)
        case .cancelled(let afterSending): return lang.t(afterSending ? .sfCancelledSending : .sfCancelled)
        case .noAudio: return lang.t(.sfNoAudio)
        case .transport(let failure):
            switch failure {
            case .offline: return lang.t(.sfOffline)
            case .timeout: return lang.t(.sfTimeout)
            case .secureConnection: return lang.t(.sfSecure)
            case .network(let code): return lang.t(.sfNetwork, String(code))
            }
        case .finished(let outcome):
            switch outcome {
            case .matched(let song): return "\(song.title) — \(song.artist)"
            case .noMatch: return lang.t(.sfNoMatch)
            case .rateLimited: return lang.t(.sfRateLimited)
            case .refused(let code): return lang.t(.sfRefused, String(code))
            case .tooLarge: return lang.t(.sfTooLarge)
            case .serverError(let code): return lang.t(.sfServerError, String(code))
            case .serviceError(let text, let code): return lang.t(.sfServiceError, text ?? "HTTP \(code)")
            case .badResponse(let code): return lang.t(.sfBadResponse, String(code))
            }
        case .needsConsent, .preparing, .listening, .sending: return ""
        }
    }
}
