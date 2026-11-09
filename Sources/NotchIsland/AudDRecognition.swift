import AppKit
import AVFoundation
import SwiftUI

// MARK: - AudD protocol (pure, testable)

/// AudD (https://audd.io) is a third-party, paid music-recognition API.
/// Facts used here come from its docs and pricing page (checked 2026-11-09):
/// POST https://api.audd.io/ with `api_token` + `file` (multipart); the
/// standard endpoint analyses up to the first 12 s; new accounts get a trial
/// of 300 requests for 14 days without a card, which then simply stops.
enum AudDService {
    static let endpoint = URL(string: "https://api.audd.io/")!
    static let pricingURL = URL(string: "https://audd.io/pricing/")!
    static let privacyURL = URL(string: "https://audd.io/privacy/")!
    /// Only what is needed: AudD reads at most 12 s; we send at most 10 s mono.
    static let captureSeconds = 10
    static let minimumSeconds = 3
    /// Bump when the disclosure text changes materially so the user consents again.
    static let consentVersion = 1
    static let consentKey = "NotchIsland.audd.consentVersion"

    static var keychainService: String { (Bundle.main.bundleIdentifier ?? "local.notchisland.app") + ".audd" }

    struct Song: Decodable, Equatable {
        let title: String
        let artist: String
        let songLink: String?

        enum CodingKeys: String, CodingKey { case title, artist, songLink = "song_link" }
    }

    enum Outcome: Equatable {
        case matched(Song)
        case noMatch
        /// AudD error 900: the token was rejected.
        case invalidToken
        /// AudD 901/902: request limit reached (trial or plan used up).
        case limitReached(Int)
        /// Any other AudD error code, shown as is.
        case serviceError(Int)
        /// Not an AudD JSON answer (HTTP status shown).
        case badResponse(Int)
    }

    private struct Response: Decodable {
        struct APIError: Decodable { let errorCode: Int?; enum CodingKeys: String, CodingKey { case errorCode = "error_code" } }
        let status: String
        let result: Song?
        let error: APIError?
    }

    static func parse(data: Data, httpStatus: Int) -> Outcome {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return .badResponse(httpStatus) }
        if response.status == "error" {
            switch response.error?.errorCode {
            case 900: return .invalidToken
            case let code? where code == 901 || code == 902: return .limitReached(code)
            case let code?: return .serviceError(code)
            case nil: return .badResponse(httpStatus)
            }
        }
        guard response.status == "success", (200..<300).contains(httpStatus) else { return .badResponse(httpStatus) }
        guard let song = response.result else { return .noMatch }
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        // A "match" without a title/artist is not shown as a song.
        guard !title.isEmpty, !artist.isEmpty else { return .badResponse(httpStatus) }
        return .matched(Song(title: title, artist: artist, songLink: song.songLink))
    }

    /// 16-bit mono PCM WAV. Nil for too short, too long, or silent audio, so
    /// silence is never uploaded.
    static func wave(samples: [Float], rate: Int) -> Data? {
        guard (8_000...192_000).contains(rate),
              (minimumSeconds * rate...captureSeconds * rate).contains(samples.count),
              samples.contains(where: { $0.isFinite && abs($0) >= 0.001 }) else { return nil }
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

    static func makeRequest(wav: Data, token: String, boundary: String = UUID().uuidString) -> URLRequest {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"api_token\"\r\n\r\n\(token)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body
        return request
    }

    static let shared = makeSession()

    /// Ephemeral: no cookies, no cache, no redirects (the token stays with api.audd.io).
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func validToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 512,
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return token
    }
}

// MARK: - Audio clip (in memory only)

/// Collects at most `captureSeconds` of mono audio from the input's own
/// queues. A closed clip rejects late buffers; `discard()` wipes it.
final class AudDClip: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 0
    private var closed = false
    let limitSeconds: Int

    init(limitSeconds: Int = AudDService.captureSeconds) { self.limitSeconds = limitSeconds }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let stride = buffer.stride
        let channelCount = max(1, Int(buffer.format.channelCount))
        append(count: count, rate: buffer.format.sampleRate) { index in
            var total: Float = 0
            for channel in 0..<channelCount { total += channels[channel][index * stride] }
            return total / Float(channelCount)
        }
    }

    func append(_ values: [Float], rate: Double) {
        append(count: values.count, rate: rate) { values[$0] }
    }

    private func append(count: Int, rate sampleRate: Double, value: (Int) -> Float) {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { return }
        let sampleRate = Int(sampleRate.rounded())
        lock.withLock {
            guard !closed, rate == 0 || rate == sampleRate else { return }
            if rate == 0 {
                rate = sampleRate
                samples.reserveCapacity(limitSeconds * rate)
            }
            for index in 0..<max(0, min(count, limitSeconds * rate - samples.count)) {
                samples.append(value(index))
            }
        }
    }

    var sampleCount: Int { lock.withLock { samples.count } }
    var isClosed: Bool { lock.withLock { closed } }

    func finish() -> (samples: [Float], rate: Int) {
        lock.withLock {
            closed = true
            let result = (samples, rate)
            samples.removeAll(keepingCapacity: false)
            return result
        }
    }

    func discard() {
        lock.withLock {
            closed = true
            samples.removeAll(keepingCapacity: false)
        }
    }
}

/// Where the clip's audio comes from (the real one wraps the microphone or
/// the system-output tap; tests use synthetic audio).
@MainActor
protocol AudDAudioSource: AnyObject {
    func begin(_ source: ShazamRecognizer.Source, into clip: AudDClip) -> Bool
    func end()
}

@MainActor
final class LiveAudDAudioSource: AudDAudioSource {
    private let input = MusicRecognitionAudioInput()
    func begin(_ source: ShazamRecognizer.Source, into clip: AudDClip) -> Bool {
        input.start(source, microphone: { buffer, _ in clip.append(buffer) },
                    systemAudio: { samples, rate in clip.append(samples, rate: rate) })
    }
    func end() { input.stop() }
}

// MARK: - Recognition flow

/// Nothing happens until the user has (1) consented to the disclosure,
/// (2) saved their own AudD token, and (3) pressed a source button. Then at
/// most 10 s of that source is kept in memory, sent once, and dropped.
@MainActor
final class AudDRecognition: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, listening, sending, cancelled
        case needsConsent, needsToken, keychain
        case permissionDenied, noAudio, network
        case finished(AudDService.Outcome)

        var busy: Bool { self == .preparing || self == .listening || self == .sending }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasToken = false

    private let secrets: SecretStore
    private let defaults: UserDefaults
    private let session: URLSession
    private let audio: AudDAudioSource
    private let listenDuration: Duration
    private let microphoneAccess: @Sendable () async -> Bool
    private var clip: AudDClip?
    private var task: Task<Void, Never>?
    private static let keychainGate = KeyReadGate()

    init(secrets: SecretStore = KeychainSecretStore(service: AudDService.keychainService, account: "api-token"),
         defaults: UserDefaults = .standard,
         session: URLSession = AudDService.shared,
         audio: AudDAudioSource? = nil,
         listenDuration: Duration = .seconds(AudDService.captureSeconds),
         microphoneAccess: @escaping @Sendable () async -> Bool = { await ShazamRecognizer.microphoneAccess() }) {
        self.secrets = secrets
        self.defaults = defaults
        self.session = session
        self.audio = audio ?? LiveAudDAudioSource()
        self.listenDuration = listenDuration
        self.microphoneAccess = microphoneAccess
    }

    var consented: Bool { defaults.integer(forKey: AudDService.consentKey) >= AudDService.consentVersion }

    /// Reads only whether a token exists (never displays it).
    func refreshTokenState() {
        let secrets = secrets
        let gate = Self.keychainGate
        Task { [weak self] in
            let present = await Task.detached(priority: .utility) { () -> Bool? in
                guard gate.begin() else { return nil }
                defer { gate.end() }
                // A stored-but-unreadable item (locked Keychain, or a rebuilt ad-hoc
                // app awaiting "Allow") still counts as present; start() then reports it.
                if case .failure(.missingAPIKey) = secrets.readKey() { return false }
                return true
            }.value
            if let present { self?.hasToken = present }
        }
    }

    /// Saves consent and (optionally) a new token. Returns false if the token is malformed or Keychain refused it.
    @discardableResult
    func saveSetup(consent: Bool, token: String) -> Bool {
        objectWillChange.send()
        defaults.set(consent ? AudDService.consentVersion : 0, forKey: AudDService.consentKey)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let valid = AudDService.validToken(trimmed), secrets.write(valid) else { return false }
        hasToken = true
        if phase == .needsToken || phase == .needsConsent { phase = .idle }
        return true
    }

    func removeToken() {
        secrets.delete()
        hasToken = false
    }

    func revokeConsent() {
        objectWillChange.send()
        defaults.set(0, forKey: AudDService.consentKey)
    }

    func start(source: ShazamRecognizer.Source) {
        guard !phase.busy else { return }
        guard consented else { phase = .needsConsent; return }
        phase = .preparing
        let secrets = secrets
        let gate = Self.keychainGate
        task = Task { [weak self] in
            // 1. Token from Keychain (before any audio is touched).
            let token = await Task.detached(priority: .utility) { () -> Result<String, ProviderError> in
                guard gate.begin() else { return .failure(.keychainUnavailable) }
                defer { gate.end() }
                return secrets.readKey()
            }.value
            guard let self, !Task.isCancelled else { return }
            let apiToken: String
            switch token {
            case .success(let value): apiToken = value
            case .failure(.missingAPIKey): self.phase = .needsToken; return
            case .failure: self.phase = .keychain; return
            }
            // 2. The source the user picked.
            if source == .microphone {
                let allowed = await self.microphoneAccess()
                guard !Task.isCancelled else { return }
                guard allowed else { self.phase = .permissionDenied; return }
            }
            let clip = AudDClip()
            guard self.audio.begin(source, into: clip) else { self.phase = .noAudio; return }
            self.clip = clip
            self.phase = .listening
            do { try await Task.sleep(for: self.listenDuration) } catch { return } // cancel() cleans up
            guard !Task.isCancelled else { return }
            self.audio.end()
            self.clip = nil
            var captured = clip.finish()
            // 3. One upload, then drop the audio.
            let wav = AudDService.wave(samples: captured.samples, rate: captured.rate)
            captured.samples.removeAll()
            guard let wav else { self.phase = .noAudio; return }
            self.phase = .sending
            let request = AudDService.makeRequest(wav: wav, token: apiToken)
            do {
                let (data, response) = try await self.session.data(for: request)
                guard !Task.isCancelled else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let outcome = AudDService.parse(data: data, httpStatus: status)
                self.phase = .finished(outcome)
            } catch {
                if !Task.isCancelled { self.phase = .network }
            }
        }
    }

    /// Stops capture/upload and wipes the clip.
    func cancel() {
        guard phase.busy else { return }
        task?.cancel()
        task = nil
        clip?.discard()
        clip = nil
        audio.end()
        phase = .cancelled
    }

    func reset() {
        if phase.busy { cancel() }
        phase = .idle
    }

    /// For tests: the in-flight clip (nil when nothing is held).
    var heldClip: AudDClip? { clip }
}

// MARK: - UI

struct AudDPage: View {
    @ObservedObject var lang: LanguageSettings
    var close: () -> Void
    @StateObject private var recognition: AudDRecognition

    init(lang: LanguageSettings, close: @escaping () -> Void, recognition: AudDRecognition? = nil) {
        self.lang = lang
        self.close = close
        _recognition = StateObject(wrappedValue: recognition ?? AudDRecognition())
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(lang.t(.audDSummary))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(status).font(.system(size: 11, weight: .semibold)).lineLimit(3)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isProblem ? .yellow : .white)
            HStack(spacing: 6) {
                if recognition.phase.busy {
                    Button(lang.t(.cancel)) { recognition.cancel() }.buttonStyle(PillStyle())
                } else {
                    if ShazamRecognizer.supportsSystemAudio {
                        Button(lang.t(.audDUploadSystem)) { start(.systemAudio) }.buttonStyle(PillStyle())
                    }
                    Button(lang.t(.audDUploadMic)) { start(.microphone) }.buttonStyle(PillStyle())
                }
            }
            HStack(spacing: 6) {
                Button(lang.t(.back)) { recognition.cancel(); close() }.buttonStyle(PillStyle())
                Button(lang.t(.audDSetup)) { showSetup() }.buttonStyle(PillStyle())
                    .disabled(recognition.phase.busy)
                if case .finished(.matched(let song)) = recognition.phase {
                    Button(lang.t(.shazamCopy)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(song.title) — \(song.artist)", forType: .string)
                    }.buttonStyle(PillStyle())
                    if let link = song.songLink.flatMap(URL.init(string:)), link.scheme == "https" {
                        Button(lang.t(.shazamOpen)) { NSWorkspace.shared.open(link) }.buttonStyle(PillStyle())
                    }
                }
            }
        }
        .onAppear { recognition.refreshTokenState() }
        .onDisappear { recognition.cancel() }
    }

    private func start(_ source: ShazamRecognizer.Source) {
        guard recognition.consented, recognition.hasToken else { showSetup(); return }
        recognition.start(source: source)
    }

    private var isProblem: Bool {
        switch recognition.phase {
        case .needsConsent, .needsToken, .keychain, .permissionDenied, .noAudio, .network: return true
        case .finished(let outcome):
            if case .matched = outcome { return false }
            return outcome != .noMatch
        default: return false
        }
    }

    private var status: String {
        switch recognition.phase {
        case .idle:
            if !recognition.consented { return lang.t(.audDNeedsConsent) }
            return recognition.hasToken ? lang.t(.audDReady) : lang.t(.audDMissingToken)
        case .preparing: return lang.t(.audDPreparing)
        case .listening: return lang.t(.audDListening)
        case .sending: return lang.t(.audDSending)
        case .cancelled: return lang.t(.audDCancelled)
        case .needsConsent: return lang.t(.audDNeedsConsent)
        case .needsToken: return lang.t(.audDMissingToken)
        case .keychain: return lang.t(.errKeychain)
        case .permissionDenied: return lang.t(.shazamMicDenied)
        case .noAudio: return lang.t(.audDNoAudio)
        case .network: return lang.t(.audDNetwork)
        case .finished(let outcome):
            switch outcome {
            case .matched(let song): return "\(song.title) — \(song.artist)"
            case .noMatch: return lang.t(.audDNoMatch)
            case .invalidToken: return lang.t(.audDInvalidToken)
            case .limitReached(let code): return lang.t(.audDLimit, String(code))
            case .serviceError(let code): return lang.t(.audDServiceError, String(code))
            case .badResponse(let code): return lang.t(.audDBadResponse, String(code))
            }
        }
    }

    /// Full disclosure + consent + token entry in a standard alert (more room
    /// than the island). The token field is secure and cleared after use.
    private func showSetup() {
        let alert = NSAlert()
        alert.messageText = lang.t(.audDSetupTitle)
        alert.informativeText = lang.t(.audDDisclosure)
        let consent = NSButton(checkboxWithTitle: lang.t(.audDConsentCheck), target: nil, action: nil)
        consent.state = recognition.consented ? .on : .off
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = lang.t(recognition.hasToken ? .audDTokenReplace : .audDToken)
        let stored = NSTextField(labelWithString: lang.t(recognition.hasToken ? .audDTokenStored : .audDTokenNone))
        stored.font = .systemFont(ofSize: 11)
        stored.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [consent, field, stored])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 78)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: lang.t(.audDSave))
        alert.addButton(withTitle: lang.t(.cancel))
        alert.addButton(withTitle: lang.t(.audDTrial))
        if recognition.hasToken { alert.addButton(withTitle: lang.t(.audDRemoveToken)) }
        NSApp.activate()
        let response = alert.runModal()
        let token = field.stringValue
        field.stringValue = ""
        switch response {
        case .alertFirstButtonReturn:
            if !recognition.saveSetup(consent: consent.state == .on, token: token) {
                let failure = NSAlert()
                failure.messageText = lang.t(.audDSetupTitle)
                failure.informativeText = lang.t(.audDTokenRejected)
                failure.addButton(withTitle: lang.t(.ok))
                failure.runModal()
            }
            if consent.state != .on { recognition.revokeConsent() }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(AudDService.pricingURL)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            recognition.removeToken()
        default:
            break
        }
        recognition.refreshTokenState()
    }
}
