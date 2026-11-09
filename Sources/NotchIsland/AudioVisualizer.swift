import AppKit
import SwiftUI
import Combine
import Accelerate
import CoreAudio
import AudioToolbox

// MARK: - Artwork palette

/// Two representative colours of an album cover, for the music gradient and
/// the level bars. Computed locally from the artwork already being shown.
struct ArtworkPalette: Equatable {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
        var saturation: Double { let mx = max(r, g, b), mn = min(r, g, b); return mx == 0 ? 0 : (mx - mn) / mx }
        var brightness: Double { max(r, g, b) }
        func distance(_ o: RGB) -> Double { ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() }
        /// Keeps white text readable on top and bars visible on black.
        func clamped(minBrightness: Double, maxBrightness: Double) -> RGB {
            let v = brightness
            guard v > 0 else { return RGB(r: minBrightness, g: minBrightness, b: minBrightness) }
            let scale = min(max(v, minBrightness), maxBrightness) / v
            return RGB(r: min(1, r * scale), g: min(1, g * scale), b: min(1, b * scale))
        }
    }

    var primary: RGB
    var secondary: RGB

    /// Downsamples to 24×24 and buckets colours (4 bits per channel). The most
    /// common vivid bucket becomes `primary`; the most common bucket clearly
    /// different from it becomes `secondary` (else a darker primary).
    static func extract(from image: NSImage) -> ArtworkPalette? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var buckets: [Int: (count: Double, r: Double, g: Double, b: Double)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let key = (Int(pixels[i]) >> 4) << 8 | (Int(pixels[i + 1]) >> 4) << 4 | (Int(pixels[i + 2]) >> 4)
            let rgb = RGB(r: r, g: g, b: b)
            // Vivid, mid-bright pixels count more than greys/near-black.
            let weight = 0.25 + rgb.saturation * 1.5 + (rgb.brightness > 0.15 ? 0.25 : 0)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.count += weight; bucket.r += r * weight; bucket.g += g * weight; bucket.b += b * weight
            buckets[key] = bucket
        }
        let ranked = buckets.values.sorted { $0.count > $1.count }
            .map { RGB(r: $0.r / $0.count, g: $0.g / $0.count, b: $0.b / $0.count) }
        guard let first = ranked.first else { return nil }
        let second = ranked.dropFirst().first { $0.distance(first) > 0.25 }
            ?? RGB(r: first.r * 0.45, g: first.g * 0.45, b: first.b * 0.45)
        return ArtworkPalette(primary: first.clamped(minBrightness: 0.45, maxBrightness: 0.95),
                              secondary: second.clamped(minBrightness: 0.2, maxBrightness: 0.7))
    }
}

// MARK: - Levels from real samples (pure DSP)

/// Reusable analyser: the DFT setup, Hann window and work buffers are created
/// once, so per-frame analysis allocates nothing but the 5-value result.
/// Not thread-safe; used from one serial queue.
final class LevelAnalyzer {
    static let size = 1024
    let sampleRate: Double
    private let setup: vDSP_DFT_Setup
    private var window = [Float](repeating: 0, count: LevelAnalyzer.size)
    private var frame = [Float](repeating: 0, count: LevelAnalyzer.size)
    private let imagIn = [Float](repeating: 0, count: LevelAnalyzer.size)
    private var real = [Float](repeating: 0, count: LevelAnalyzer.size)
    private var imag = [Float](repeating: 0, count: LevelAnalyzer.size)
    private let bins: [(lo: Int, hi: Int)]

    init?(sampleRate: Double) {
        guard sampleRate > 0, let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD) else { return nil }
        self.sampleRate = sampleRate
        self.setup = setup
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(Self.size)
        bins = (0..<AudioLevels.bandCount).map { band in
            (max(1, Int(AudioLevels.edges[band] / binHz)), min(Self.size / 2 - 1, Int(AudioLevels.edges[band + 1] / binHz)))
        }
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// `samples` must hold `size` values (oldest first).
    func bands(_ samples: UnsafePointer<Float>) -> [Float] {
        vDSP_vmul(samples, 1, window, 1, &frame, 1, vDSP_Length(Self.size))
        vDSP_DFT_Execute(setup, frame, imagIn, &real, &imag)
        let quarter = Float(Self.size / 4) // a full-scale sine with a Hann window ≈ n/4 in its bin
        return bins.map { lo, hi in
            guard hi >= lo else { return 0 }
            var power: Float = 0
            for k in lo...hi { power += real[k] * real[k] + imag[k] * imag[k] }
            let count = Float(hi - lo + 1)
            let amplitude = (power / count).squareRoot() / quarter
            return AudioLevels.level(fromAmplitude: amplitude * count.squareRoot())
        }
    }
}

/// Fixed-capacity mono sample ring (no allocation after init).
struct SampleRing {
    private(set) var storage: [Float]
    private(set) var written = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity; storage = [Float](repeating: 0, count: capacity) }

    mutating func append(_ value: Float) {
        storage[written % capacity] = value
        written &+= 1
    }

    /// Copies the newest `count` samples, oldest first, into `out` (zero-padded at the start).
    func copyLatest(_ count: Int, into out: inout [Float]) {
        let n = min(count, capacity)
        let available = min(written, n)
        for i in 0..<(n - available) { out[i] = 0 }
        for i in 0..<available {
            out[n - available + i] = storage[(written - available + i) % capacity]
        }
    }
}

enum AudioLevels {
    static let bandCount = 5
    /// Log-spaced band edges in Hz.
    static let edges: [Double] = [60, 250, 700, 1800, 4500, 12000]

    /// Band levels 0…1 from mono samples (dBFS mapped from −60…0). One-off
    /// convenience (tests, diagnostics); live capture uses a cached `LevelAnalyzer`.
    static func bands(_ samples: [Float], sampleRate: Double) -> [Float] {
        let n = LevelAnalyzer.size
        guard samples.count >= 64, let analyzer = LevelAnalyzer(sampleRate: sampleRate) else { return Array(repeating: 0, count: bandCount) }
        var frame = Array(samples.suffix(n))
        if frame.count < n { frame = Array(repeating: 0, count: n - frame.count) + frame }
        return frame.withUnsafeBufferPointer { analyzer.bands($0.baseAddress!) }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }

    static func level(fromAmplitude amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10(amplitude)
        return max(0, min(1, (db + 60) / 60))
    }

    /// Fast attack, slower release, so bars follow the music without flicker.
    static func smooth(previous: [Float], next: [Float], attack: Float = 0.6, release: Float = 0.18) -> [Float] {
        guard previous.count == next.count else { return next }
        return zip(previous, next).map { p, n in n > p ? p + (n - p) * attack : p + (n - p) * release }
    }

    /// Averages channels of one IO buffer list straight into the ring (no allocation).
    static func appendMono(_ list: UnsafePointer<AudioBufferList>, interleaved: Bool, channels: Int, to ring: inout SampleRing) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mData != nil else { return }
        if interleaved {
            let channels = max(1, channels)
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = first.mData!.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(channels)
            var f = 0
            while f + channels <= count {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f + c] }
                ring.append(sum * scale)
                f += channels
            }
            return
        }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let scale = 1 / Float(max(1, buffers.count))
        for i in 0..<frames {
            var sum: Float = 0
            for buffer in buffers {
                guard let p = buffer.mData, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size > i else { continue }
                sum += p.assumingMemoryBound(to: Float.self)[i]
            }
            ring.append(sum * scale)
        }
    }
}

// MARK: - System audio tap (public Core Audio API, macOS 14.2+)

/// Captures the system output mix (all apps except Notch Island) with a Core
/// Audio process tap, only while the user has turned this on and media plays.
/// Audio stays in memory: samples go into a small ring buffer and are reduced
/// to a few band levels ~30 times a second — nothing is stored, recorded or
/// sent. macOS asks for the "System Audio Recording" permission the first time.
///
/// Performance: the IO block only averages channels into a preallocated ring
/// (no allocation, no FFT). Analysis runs on the same serial queue from a
/// 30 Hz timer with a cached DFT setup, so it never overlaps the IO block and
/// the main thread is updated at most 30 times a second.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: Error, Equatable { case processObject, createTap(OSStatus), noOutputDevice, aggregate(OSStatus), format, ioProc(OSStatus), start(OSStatus) }

    static let analysisRate: Double = 30

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "NotchIsland.AudioTap", qos: .userInteractive)
    // Touched only on `queue`.
    /// ~170 ms at 48 kHz: enough slack between 30 Hz timer ticks.
    static let ringCapacity = LevelAnalyzer.size * 8
    private var ring = SampleRing(capacity: SystemAudioTap.ringCapacity)
    private var window = [Float](repeating: 0, count: LevelAnalyzer.size)
    private var analyzer: LevelAnalyzer?
    private var timer: DispatchSourceTimer?
    private var active = false
    private var lastAnalysedCount = 0
    private var stopped = false
    private static let queueKey = DispatchSpecificKey<Bool>()

    init() { queue.setSpecific(key: Self.queueKey, value: true) }

    /// Runs `work` serialised with the IO block and timer, without deadlocking
    /// if we're already on the tap queue.
    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { work() } else { queue.sync(execute: work) }
    }

    /// `onLevels(bands)` runs on the tap's queue at ≤ 30 Hz.
    /// `onSamples(mono, sampleRate)` (optional, same queue) receives the new
    /// samples since the previous tick — used by Shazam while it listens.
    func start(onLevels: @escaping @Sendable ([Float]) -> Void,
               onSamples: (@Sendable ([Float], Double) -> Void)? = nil) throws {
        // Exclude our own process so the island never visualises itself.
        var own = AudioObjectID(kAudioObjectUnknown)
        var pid = getpid()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let pidStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)
        let exclude: [AudioObjectID] = pidStatus == noErr && own != kAudioObjectUnknown ? [own] : []

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw TapError.createTap(tapStatus) }
        tapID = tap

        // The device music normally plays on (not the alert/sound-effects device).
        guard let outputUID = Self.defaultOutputUID() else { stop(); throw TapError.noOutputDevice }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Island Level Meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard aggStatus == noErr else { stop(); throw TapError.aggregate(aggStatus) }
        aggregateID = aggregateDevice

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format) == noErr,
              format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              let analyzer = LevelAnalyzer(sampleRate: format.mSampleRate) else {
            stop(); throw TapError.format
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(max(1, format.mChannelsPerFrame))
        onQueue {
            self.analyzer = analyzer
            self.ring = SampleRing(capacity: Self.ringCapacity)
            self.lastAnalysedCount = 0
            self.active = true
        }

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, queue) { [weak self] _, input, _, _, _ in
            // Keep this minimal: no allocation, no analysis.
            guard let self, self.active else { return }
            AudioLevels.appendMono(input, interleaved: interleaved, channels: channels, to: &self.ring)
        }
        guard ioStatus == noErr, let proc else { stop(); throw TapError.ioProc(ioStatus) }
        procID = proc

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1 / Self.analysisRate, repeating: 1 / Self.analysisRate, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.active, let analyzer = self.analyzer else { return }
            // Nothing new since last time (IO stalled / device gone): don't repeat stale levels.
            guard self.ring.written != self.lastAnalysedCount else { onLevels(Array(repeating: 0, count: AudioLevels.bandCount)); return }
            if let onSamples {
                let fresh = min(self.ring.written &- self.lastAnalysedCount, Self.ringCapacity)
                var chunk = [Float](repeating: 0, count: fresh)
                self.ring.copyLatest(fresh, into: &chunk)
                onSamples(chunk, analyzer.sampleRate)
            }
            self.lastAnalysedCount = self.ring.written
            self.ring.copyLatest(LevelAnalyzer.size, into: &self.window)
            let bands = self.window.withUnsafeBufferPointer { analyzer.bands($0.baseAddress!) }
            onLevels(bands)
        }
        onQueue { self.timer = timer }
        timer.resume()

        let startStatus = AudioDeviceStart(aggregateDevice, proc)
        guard startStatus == noErr else { stop(); throw TapError.start(startStatus) }
    }

    /// Stops IO, then drains the queue so no callback from this session runs afterwards.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        onQueue {
            active = false
            timer?.cancel()
            timer = nil
            analyzer = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Default *output* device (where music plays). `…DefaultSystemOutputDevice`
    /// is the alert / sound-effects device and can differ.
    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: outputDeviceSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    static let outputDeviceSelector = kAudioHardwarePropertyDefaultOutputDevice

    private static func defaultOutputUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - Monitor (opt-in, published levels)

@MainActor
final class AudioLevelMonitor: ObservableObject {
    enum State: Equatable {
        /// Off by default; no audio is touched.
        case off
        /// macOS older than 14.2 has no process taps.
        case unsupported
        /// Turned on; waiting for something to play.
        case idle
        case running
        /// Started but only silence arrives while media plays (permission
        /// denied, or the source is silent/muted) — shown as a hint.
        case silent
        case failed
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var state: State
    /// Smoothed real band levels (0…1); nil whenever no real audio data is available.
    @Published private(set) var levels: [Float]?

    private let defaults: UserDefaults
    private static let key = "NotchIsland.media.audioLevels"
    private var tap: AnyObject?
    private var startedAt: Date?
    private var lastNonSilent: Date?
    private var mediaPlaying = false
    /// Incremented per capture session; results from an older session are dropped.
    private(set) var session = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var restartWork: DispatchWorkItem?
    private var terminateObserver: NSObjectProtocol?

    static var isSupported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.key)
        state = defaults.bool(forKey: Self.key) ? (Self.isSupported ? .idle : .unsupported) : .off
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCapture() }
        }
    }

    /// Explicit user choice in Settings. The system permission prompt appears
    /// the first time capture actually starts (i.e. while media plays).
    func setEnabled(_ on: Bool, mediaPlaying: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.key)
        if !on { stopCapture(); state = .off; return }
        state = Self.isSupported ? .idle : .unsupported
        update(mediaPlaying: mediaPlaying)
    }

    /// Capture only while enabled and something is playing.
    func update(mediaPlaying: Bool) {
        self.mediaPlaying = mediaPlaying
        guard enabled, Self.isSupported else { return }
        if mediaPlaying { startCapture() } else { stopCapture(); if state != .failed { state = .idle } }
    }

    func openPrivacySettings() {
        // Screen & System Audio Recording pane (where "System Audio Recording Only" is listed).
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startCapture() {
        guard tap == nil else { return }
        guard #available(macOS 14.2, *) else { state = .unsupported; return }
        session += 1
        let current = session
        let instance = SystemAudioTap()
        do {
            try instance.start { [weak self] bands in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(bands, session: current) } }
            }
            tap = instance
            state = .running
            startedAt = Date()
            lastNonSilent = nil
            observeOutputDevice()
        } catch {
            instance.stop()
            levels = nil
            state = .failed
        }
    }

    private func stopCapture() {
        session += 1 // anything still in flight from the old session is ignored
        restartWork?.cancel(); restartWork = nil
        removeOutputDeviceObserver()
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
        levels = nil
    }

    /// Output device changed (headphones, AirPods, display audio…): the
    /// aggregate device is bound to the old one, so rebuild the capture.
    private func observeOutputDevice() {
        guard deviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.outputDeviceChanged() } }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener) == noErr {
            deviceListener = listener
        }
    }

    private func removeOutputDeviceObserver() {
        guard let listener = deviceListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        deviceListener = nil
    }

    func outputDeviceChanged() {
        guard enabled, tap != nil else { return }
        // Devices often change in bursts; rebuild once things settle.
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.stopCapture()
                if self.mediaPlaying { self.startCapture() } else { self.state = .idle }
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Exposed for tests: results are applied only for the current session.
    func receive(_ bands: [Float], session: Int) {
        guard session == self.session, tap != nil else { return }
        let now = Date()
        let audible = (bands.max() ?? 0) > 0.05
        if audible { lastNonSilent = now }
        // Silence for a while although media plays → say so instead of drawing bars.
        let newState = Self.classify(lastNonSilent: lastNonSilent, startedAt: startedAt ?? now, now: now)
        if state != newState { state = newState }
        levels = newState == .running ? AudioLevels.smooth(previous: levels ?? bands, next: bands) : nil
    }

    nonisolated static func classify(lastNonSilent: Date?, startedAt: Date, now: Date, grace: TimeInterval = 4) -> State {
        if let lastNonSilent, now.timeIntervalSince(lastNonSilent) < grace { return .running }
        return now.timeIntervalSince(startedAt) < grace ? .running : .silent
    }
}

// MARK: - Views

/// The original equalizer bars (4 capsules, 2.5 pt wide, up to 12 pt tall,
/// |sin| rhythm at 5.2 + 1.3·i rad/s, phase 1.7·i; resting at 25 % when
/// paused), now filled with a gradient from the album cover's colours.
///
/// The motion is decorative by default and is not described anywhere as the
/// sound's level. Only when "Show real audio levels" is on *and* real band
/// data is arriving do the heights follow those bands (same 35–100 % range).
struct MusicBars: View {
    var isPlaying: Bool
    var palette: ArtworkPalette? = nil
    /// Real band levels (0…1) from `AudioLevelMonitor`, or nil.
    var realLevels: [Float]? = nil

    static let barCount = 4

    /// The decorative glyph retains its original dimensions. Give a live
    /// signal a little more vertical room at both placements.
    static func height(isPlaying: Bool, realLevels: [Float]?) -> CGFloat {
        isPlaying && realLevels?.isEmpty == false ? 15 : 12
    }

    /// Height fraction of bar `index` (pure, for tests).
    static func level(index: Int, time: TimeInterval, isPlaying: Bool, realLevels: [Float]?) -> Double {
        guard isPlaying else { return 0.25 }
        if let realLevels, !realLevels.isEmpty {
            let value = Double(realLevels[min(index, realLevels.count - 1)])
            return 0.35 + 0.65 * min(1, max(0, value))
        }
        let phase = time * (5.2 + Double(index) * 1.3) + Double(index) * 1.7
        return 0.35 + 0.65 * abs(sin(phase))
    }

    /// Top → bottom fill: cover colours when known, else the original green.
    static func colors(for palette: ArtworkPalette?) -> [Color] {
        guard let palette else { return [Color.green.opacity(0.9), Color.green.opacity(0.9)] }
        return [palette.primary.color, palette.secondary.color]
    }

    var body: some View {
        let gradient = LinearGradient(colors: Self.colors(for: palette), startPoint: .top, endPoint: .bottom)
        let height = Self.height(isPlaying: isPlaying, realLevels: realLevels)
        // Paused → the timeline stops and the bars rest, as before.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(gradient)
                        .frame(width: 2.5)
                        .frame(height: height * Self.level(index: i, time: t, isPlaying: isPlaying, realLevels: realLevels))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 18, height: height)
        .animation(.easeInOut(duration: 0.6), value: palette)
        .accessibilityHidden(true)
    }
}
