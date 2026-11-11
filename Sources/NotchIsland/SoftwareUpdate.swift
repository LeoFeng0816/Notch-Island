import AppKit
import CryptoKit
import CoreServices
import SwiftUI

// MARK: - Versions

/// Strict `X.Y.Z` (optionally `vX.Y.Z`). Anything else — pre-release suffixes, build
/// metadata, four parts — is not a version this updater will offer.
struct AppVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) { (self.major, self.minor, self.patch) = (major, minor, patch) }

    init?(_ text: String) {
        var body = Substring(text)
        if body.hasPrefix("v") { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }
}

// MARK: - GitHub release (pure, testable)

/// The only release source: GitHub's documented REST endpoint
/// `GET /repos/{owner}/{repo}/releases/latest` ("the most recent non-prerelease,
/// non-draft release"). Checked 2026-11-11 against the live v0.1.1 answer: `tag_name`,
/// `name`, `body`, `draft`, `prerelease`, `html_url`, `published_at`, and per asset
/// `name`, `state`, `size`, `digest` ("sha256:<hex>"), `browser_download_url`.
enum ReleaseSource {
    static let owner = "LeoFeng0816"
    static let repo = "Notch-Island"
    static let latestAPI = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    /// github.com answers a release download with a redirect to its asset CDN.
    static let downloadHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
    static let maxAssetBytes = 300 * 1024 * 1024

    static func pageURL(tag: String) -> String { "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)" }
    static func downloadURL(tag: String, name: String) -> String { "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(name)" }
    static func assetName(_ version: AppVersion) -> String { "NotchIsland-\(version).dmg" }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "NotchIsland/\(version) (+https://github.com/\(owner)/\(repo))"
    }

    static func latestRequest() -> URLRequest {
        var request = URLRequest(url: latestAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// Ephemeral, no cookies; the API request follows no redirect.
    static func makeAPISession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    struct Asset: Equatable {
        var name: String
        var url: URL
        var size: Int
        /// Lower-case hex SHA-256 from GitHub's `digest`.
        var sha256: String
    }

    enum AssetProblem: Error, Equatable {
        /// No `NotchIsland-X.Y.Z.dmg` matching the tag.
        case missing
        case duplicate
        /// `state` isn't "uploaded".
        case notUploaded
        case unexpectedURL
        /// GitHub lists no `sha256:` digest, so the file can't be checked in the app.
        case noDigest
        case badSize
    }

    struct Offer: Equatable {
        var version: AppVersion
        var tag: String
        var title: String
        var notes: String
        var pageURL: URL
        var publishedAt: Date?
        var asset: Result<Asset, AssetProblem>
    }

    enum CheckResult: Equatable {
        case available(Offer)
        case upToDate(latest: AppVersion)
        /// This build is newer than the latest published release: never offered as a "downgrade".
        case newerThanLatest(latest: AppVersion)
    }

    enum CheckFailure: Error, Equatable {
        case offline, timeout
        case network(Int)
        case rateLimited(resetAt: Date?)
        /// 404: the repository has no published (non-draft, non-prerelease) release.
        case noRelease
        case http(Int)
        case badResponse
        /// A draft or pre-release came back; it's not an update.
        case prerelease
        case unrecognizedTag(String)
        /// `html_url` isn't this repository's release page.
        case untrustedPage
        case currentVersionUnknown
    }

    private struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let htmlURL: String
        let publishedAt: String?
        let assets: [RawAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, draft, prerelease, htmlURL = "html_url", publishedAt = "published_at", assets
        }
    }

    private struct RawAsset: Decodable {
        let name: String
        let state: String?
        let size: Int
        let digest: String?
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey { case name, state, size, digest, browserDownloadURL = "browser_download_url" }
    }

    static func evaluate(data: Data, status: Int, headers: [String: String] = [:],
                         current: AppVersion?) -> Result<CheckResult, CheckFailure> {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        if status == 429 || (status == 403 && lowered["x-ratelimit-remaining"] == "0") {
            let reset = lowered["x-ratelimit-reset"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            return .failure(.rateLimited(resetAt: reset))
        }
        if status == 404 { return .failure(.noRelease) }
        guard status == 200 else { return .failure(.http(status)) }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return .failure(.badResponse) }
        guard !release.draft, !release.prerelease else { return .failure(.prerelease) }
        guard let latest = AppVersion(release.tagName) else { return .failure(.unrecognizedTag(String(release.tagName.prefix(40)))) }
        guard release.htmlURL == pageURL(tag: release.tagName), let page = URL(string: release.htmlURL) else {
            return .failure(.untrustedPage)
        }
        guard let current else { return .failure(.currentVersionUnknown) }
        if latest == current { return .success(.upToDate(latest: latest)) }
        if latest < current { return .success(.newerThanLatest(latest: latest)) }
        let offer = Offer(version: latest, tag: release.tagName,
                          title: cleaned(release.name ?? "", limit: 120).isEmpty ? "Notch Island \(latest)" : cleaned(release.name ?? "", limit: 120),
                          notes: cleaned(release.body ?? "", limit: 8_000),
                          pageURL: page,
                          publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                          asset: pickAsset(release.assets, tag: release.tagName, version: latest))
        return .success(.available(offer))
    }

    private static func pickAsset(_ assets: [RawAsset], tag: String, version: AppVersion) -> Result<Asset, AssetProblem> {
        let wanted = assetName(version)
        let matches = assets.filter { $0.name == wanted }
        guard !matches.isEmpty else { return .failure(.missing) }
        guard matches.count == 1, let raw = matches.first else { return .failure(.duplicate) }
        if let state = raw.state, state != "uploaded" { return .failure(.notUploaded) }
        guard raw.browserDownloadURL == downloadURL(tag: tag, name: wanted), let url = URL(string: raw.browserDownloadURL) else {
            return .failure(.unexpectedURL)
        }
        guard (1...maxAssetBytes).contains(raw.size) else { return .failure(.badSize) }
        guard let hex = sha256Hex(fromDigest: raw.digest) else { return .failure(.noDigest) }
        return .success(Asset(name: wanted, url: url, size: raw.size, sha256: hex))
    }

    static func sha256Hex(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return String(hex)
    }

    /// Release text from GitHub is shown as data: CR/LF normalized, control characters removed, capped.
    static func cleaned(_ text: String, limit: Int) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let scalars = normalized.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count > limit ? String(result.prefix(limit)) + "…" : result
    }

    static func checkFailure(for error: Error) -> CheckFailure {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .network(ns.code) }
        switch URLError.Code(rawValue: ns.code) {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            return .offline
        default: return .network(ns.code)
        }
    }
}

// MARK: - Download (verified, never installed)

/// Follows only HTTPS redirects to GitHub's own download hosts, and remembers a refusal
/// (used per download, so a refused redirect is reported as such however the task ends).
final class TrustedReleaseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refusedRedirect = false
    var refused: Bool { lock.withLock { refusedRedirect } }

    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ReleaseSource.downloadHosts.contains(host)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = Self.allows(request.url)
        if !allowed { lock.withLock { refusedRedirect = true } }
        completionHandler(allowed ? request : nil)
    }
}

enum UpdateDownload {
    enum Failure: Error, Equatable {
        case offline, timeout
        case network(Int)
        /// A redirect (or final address) outside GitHub's download hosts.
        case redirectRefused
        case http(Int)
        case sizeMismatch(expected: Int, actual: Int)
        case checksumMismatch
        case disk(String)
        case cancelled
    }

    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 15 * 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config, delegate: TrustedReleaseRedirects(), delegateQueue: nil)
    }

    /// Next free name: "NotchIsland-0.1.2.dmg", then "NotchIsland-0.1.2 (2).dmg", … — never overwrites.
    static func uniqueDestination(in directory: URL, name: String, fileManager: FileManager = .default) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
            index += 1
        }
        return candidate
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Marks the file like a browser download so Gatekeeper still checks what's inside.
    static func markQuarantined(_ url: URL, dataURL: URL, originURL: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Notch Island",
            kLSQuarantineDataURLKey as String: dataURL,
            kLSQuarantineOriginURLKey as String: originURL,
        ]
        var target = url
        try target.setResourceValues(values)
    }

    static func failure(for error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .disk(ns.localizedDescription) }
        switch URLError.Code(rawValue: ns.code) {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .offline
        default: return .network(ns.code)
        }
    }

    /// Streams the asset into a private staging folder while hashing it, checks the exact
    /// size and GitHub's SHA-256, then moves it (never over an existing file) into the
    /// first writable destination and marks it quarantined. Nothing is opened or run.
    static func download(_ asset: ReleaseSource.Asset, pageURL: URL, session: URLSession, destinations: [URL],
                         fileManager: FileManager = .default,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        var request = URLRequest(url: asset.url, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(ReleaseSource.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let staging = fileManager.temporaryDirectory.appendingPathComponent("NotchIsland-Update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let redirects = TrustedReleaseRedirects()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            guard let http = response as? HTTPURLResponse else { throw Failure.network(0) }
            if (300..<400).contains(http.statusCode) { throw Failure.redirectRefused }
            guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
            guard TrustedReleaseRedirects.allows(http.url) else { throw Failure.redirectRefused }
            if http.expectedContentLength > 0, http.expectedContentLength != Int64(asset.size) {
                throw Failure.sizeMismatch(expected: asset.size, actual: Int(http.expectedContentLength))
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let part = staging.appendingPathComponent(asset.name + ".part")
            guard fileManager.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.disk("staging")
            }
            let handle = try FileHandle(forWritingTo: part)
            var hasher = SHA256()
            var total = 0
            var buffer = [UInt8]()
            buffer.reserveCapacity(1 << 16)
            func flush() throws {
                guard !buffer.isEmpty else { return }
                total += buffer.count
                guard total <= asset.size else { throw Failure.sizeMismatch(expected: asset.size, actual: total) }
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(min(1, Double(total) / Double(asset.size)))
            }
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count == 1 << 16 { try flush() }
                }
                try flush()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard total == asset.size else { throw Failure.sizeMismatch(expected: asset.size, actual: total) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == asset.sha256 else { throw Failure.checksumMismatch }
            var lastError: Error = Failure.disk("no destination")
            for directory in destinations {
                let destination: URL
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    destination = uniqueDestination(in: directory, name: asset.name, fileManager: fileManager)
                    try fileManager.moveItem(at: part, to: destination)
                } catch {
                    lastError = error
                    continue // e.g. Downloads not allowed → next folder
                }
                do {
                    try markQuarantined(destination, dataURL: asset.url, originURL: pageURL)
                } catch {
                    // Never leave an unquarantined copy behind.
                    try? fileManager.removeItem(at: destination)
                    throw Failure.disk("quarantine: " + (error as NSError).localizedDescription)
                }
                return destination
            }
            throw Failure.disk((lastError as NSError).localizedDescription)
        } catch {
            if redirects.refused { throw Failure.redirectRefused }
            throw failure(for: error)
        }
    }
}

// MARK: - Install location and backup

enum InstallLocation: Equatable {
    /// macOS runs an unmoved download from a randomized read-only path (App Translocation).
    case translocated
    /// e.g. still running from the mounted disk image.
    case readOnlyVolume
    /// Replacing it here needs an administrator (Finder will ask).
    case notWritable(folder: URL)
    case writable(folder: URL)

    /// `statfs` MNT_RDONLY: true for a mounted disk image and for the sealed system volume
    /// (where `URLResourceValues.volumeIsReadOnly` reports false on macOS 27).
    static func isReadOnlyVolume(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.deletingLastPathComponent().path, &info) == 0 else {
            return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        }
        return (Int32(bitPattern: info.f_flags) & MNT_RDONLY) != 0
    }

    static func assess(_ bundleURL: URL, fileManager: FileManager = .default) -> InstallLocation {
        if bundleURL.path.contains("/AppTranslocation/") { return .translocated }
        if isReadOnlyVolume(bundleURL) { return .readOnlyVolume }
        let folder = bundleURL.deletingLastPathComponent()
        return fileManager.isWritableFile(atPath: folder.path) ? .writable(folder: folder) : .notWritable(folder: folder)
    }
}

enum AppBackup {
    enum Failure: Error, Equatable { case notAnApp, tool(Int32), disk(String) }

    static func archiveName(version: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Notch Island \(version) backup \(formatter.string(from: date)).zip"
    }

    /// Zips the current app with the system's `ditto` (keeps its signature and metadata).
    /// The zip isn't an app, so Launch Services won't open it instead of the new version.
    static func backup(app: URL, version: String, into directory: URL, fileManager: FileManager = .default) async throws -> URL {
        guard app.pathExtension == "app", fileManager.fileExists(atPath: app.appendingPathComponent("Contents").path) else {
            throw Failure.notAnApp
        }
        do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw Failure.disk((error as NSError).localizedDescription) }
        let destination = UpdateDownload.uniqueDestination(in: directory, name: archiveName(version: version), fileManager: fileManager)
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, destination.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        guard status == 0, fileManager.fileExists(atPath: destination.path) else {
            try? fileManager.removeItem(at: destination)
            throw Failure.tool(status)
        }
        return destination
    }
}

// MARK: - Controller

@MainActor
final class SoftwareUpdateController: ObservableObject {
    enum CheckState: Equatable {
        case idle, checking
        case done(ReleaseSource.CheckResult)
        case failed(ReleaseSource.CheckFailure)
    }
    enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case verified(URL)
        case failed(UpdateDownload.Failure)
    }
    enum BackupState: Equatable { case idle, working, done(URL), failed(AppBackup.Failure) }

    @Published private(set) var check: CheckState = .idle
    @Published private(set) var download: DownloadState = .idle
    @Published private(set) var backup: BackupState = .idle

    let currentVersion: AppVersion?
    let bundleURL: URL
    private let apiSession: URLSession
    private let downloadSession: URLSession
    private let destinations: [URL]
    private let backupsDirectory: URL
    private var downloadTask: Task<Void, Never>?

    nonisolated static var defaultDestinations: [URL] {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NotchIsland/Updates", isDirectory: true)
        return [downloads, support].compactMap { $0 }
    }

    nonisolated static var defaultBackupsDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("NotchIsland/Backups", isDirectory: true)
    }

    init(apiSession: URLSession = ReleaseSource.makeAPISession(),
         downloadSession: URLSession = UpdateDownload.makeSession(),
         currentVersion: AppVersion? = AppVersion.current,
         bundleURL: URL = Bundle.main.bundleURL,
         destinations: [URL] = SoftwareUpdateController.defaultDestinations,
         backupsDirectory: URL = SoftwareUpdateController.defaultBackupsDirectory) {
        self.apiSession = apiSession
        self.downloadSession = downloadSession
        self.currentVersion = currentVersion
        self.bundleURL = bundleURL
        self.destinations = destinations
        self.backupsDirectory = backupsDirectory
    }

    var currentVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short ?? currentVersion?.description, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "?"
        }
    }

    var location: InstallLocation { InstallLocation.assess(bundleURL) }

    var offer: ReleaseSource.Offer? {
        if case .done(.available(let offer)) = check { return offer }
        return nil
    }

    /// Only from the user's click. Contacts api.github.com once.
    func checkNow() {
        guard check != .checking else { return }
        check = .checking
        let request = ReleaseSource.latestRequest()
        let current = currentVersion
        Task {
            do {
                let (data, response) = try await apiSession.data(for: request)
                let http = response as? HTTPURLResponse
                let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
                    if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
                }
                switch ReleaseSource.evaluate(data: data, status: http?.statusCode ?? 0, headers: headers, current: current) {
                case .success(let result):
                    if case .done(.available(let old)) = check, case .available(let new) = result, old.version != new.version {
                        download = .idle
                    }
                    check = .done(result)
                case .failure(let failure): check = .failed(failure)
                }
            } catch {
                check = .failed(ReleaseSource.checkFailure(for: error))
            }
        }
    }

    /// Only from the user's click. Downloads and verifies; never opens, installs or replaces anything.
    func downloadUpdate() {
        guard let offer, case .success(let asset) = offer.asset else { return }
        if case .downloading = download { return }
        download = .downloading(0)
        let session = downloadSession
        let destinations = destinations
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.download else { return }
                self.download = .downloading(fraction)
            }
        }
        downloadTask = Task {
            do {
                let url = try await UpdateDownload.download(asset, pageURL: offer.pageURL, session: session,
                                                            destinations: destinations, progress: report)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                download = .verified(url)
            } catch {
                guard !Task.isCancelled else { return }
                download = .failed(UpdateDownload.failure(for: error))
            }
            downloadTask = nil
        }
    }

    func cancelDownload() {
        guard case .downloading = download else { return }
        downloadTask?.cancel()
        downloadTask = nil
        download = .failed(.cancelled)
    }

    /// Only from the user's click. Zips the running app into Application Support.
    func backupCurrentApp() {
        guard backup != .working else { return }
        backup = .working
        let app = bundleURL
        let version = currentVersion?.description ?? "unknown"
        let directory = backupsDirectory
        Task {
            do { backup = .done(try await AppBackup.backup(app: app, version: version, into: directory)) }
            catch { backup = .failed(error as? AppBackup.Failure ?? .disk((error as NSError).localizedDescription)) }
        }
    }
}

// MARK: - Settings section

struct SoftwareUpdateSection: View {
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var updater: SoftwareUpdateController

    var body: some View {
        Section {
            HStack {
                Text(lang.t(.updCurrent, updater.currentVersionText))
                Spacer()
                if updater.check == .checking { ProgressView().controlSize(.small) }
                Button(lang.t(.updCheck)) { updater.checkNow() }.disabled(updater.check == .checking)
            }
            checkStatus
            if let offer = updater.offer { offerView(offer) }
        } header: {
            Text(lang.t(.updSection))
        } footer: {
            Text(lang.t(.updPrivacy)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var checkStatus: some View {
        switch updater.check {
        case .idle, .checking: EmptyView()
        case .done(.available(let offer)):
            Text(lang.t(.updAvailable, offer.version.description, offer.publishedAt.map { $0.formatted(.dateTime.year().month().day().locale(lang.locale)) } ?? "—"))
                .font(.headline)
        case .done(.upToDate(let latest)):
            Label(lang.t(.updUpToDate, latest.description), systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .done(.newerThanLatest(let latest)):
            Label(lang.t(.updNewer, updater.currentVersion?.description ?? "?", latest.description), systemImage: "info.circle").foregroundStyle(.secondary)
        case .failed(let failure):
            Label(failureText(failure), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func offerView(_ offer: ReleaseSource.Offer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(offer.title).font(.subheadline.weight(.semibold))
            if !offer.notes.isEmpty {
                Text(lang.t(.updNotes)).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(notes(offer.notes)).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            HStack {
                switch offer.asset {
                case .success:
                    downloadControls
                case .failure(let problem):
                    Text(lang.t(.updNoAsset, ReleaseSource.assetName(offer.version), problemText(problem)))
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button(lang.t(.updViewOnGitHub)) { NSWorkspace.shared.open(offer.pageURL) }
            }
            if case .verified(let file) = updater.download { installGuide(file) }
        }
    }

    @ViewBuilder private var downloadControls: some View {
        switch updater.download {
        case .idle, .failed:
            Button(lang.t(.updDownload)) { updater.downloadUpdate() }
            if case .failed(let failure) = updater.download {
                Text(downloadFailureText(failure)).font(.caption).foregroundStyle(.orange)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 140)
            Button(lang.t(.cancel)) { updater.cancelDownload() }
        case .verified:
            Label(lang.t(.updVerifiedShort), systemImage: "checkmark.seal").foregroundStyle(.green)
        }
    }

    @ViewBuilder private func installGuide(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.t(.updVerified, file.path)).font(.caption).textSelection(.enabled)
            Text(lang.t(.updAuthenticity)).font(.caption).foregroundStyle(.secondary)
            locationNote
            Text(lang.t(.updSteps)).font(.caption)
            Text(lang.t(.updGatekeeper)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(lang.t(.updBackup)) { updater.backupCurrentApp() }
                    .disabled(updater.backup == .working || updater.bundleURL.pathExtension != "app")
                Button(lang.t(.updOpenDMG)) { NSWorkspace.shared.open(file) }
                Button(lang.t(.updShowInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            switch updater.backup {
            case .idle: EmptyView()
            case .working: Text(lang.t(.updBackingUp)).font(.caption)
            case .done(let zip):
                HStack {
                    Text(lang.t(.updBackupDone, zip.path)).font(.caption).textSelection(.enabled)
                    Button(lang.t(.updShowInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
                }
            case .failed(let failure):
                Text(lang.t(.updBackupFailed, backupFailureText(failure))).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var locationNote: some View {
        switch updater.location {
        case .translocated: Text(lang.t(.updLocTranslocated)).font(.caption).foregroundStyle(.orange)
        case .readOnlyVolume: Text(lang.t(.updLocReadOnly)).font(.caption).foregroundStyle(.orange)
        case .notWritable(let folder): Text(lang.t(.updLocNeedsAdmin, folder.path)).font(.caption).foregroundStyle(.secondary)
        case .writable: Text(lang.t(.updLocCurrent, updater.bundleURL.path)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func notes(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func problemText(_ problem: ReleaseSource.AssetProblem) -> String {
        switch problem {
        case .missing: return lang.t(.updProblemMissing)
        case .duplicate: return lang.t(.updProblemDuplicate)
        case .notUploaded: return lang.t(.updProblemNotUploaded)
        case .unexpectedURL: return lang.t(.updProblemURL)
        case .noDigest: return lang.t(.updProblemDigest)
        case .badSize: return lang.t(.updProblemSize)
        }
    }

    private func failureText(_ failure: ReleaseSource.CheckFailure) -> String {
        switch failure {
        case .offline: return lang.t(.updOffline)
        case .timeout: return lang.t(.updTimeout)
        case .network(let code): return lang.t(.updNetwork, String(code))
        case .rateLimited(let reset):
            return lang.t(.updRateLimited, reset.map { $0.formatted(.dateTime.hour().minute().locale(lang.locale)) } ?? "—")
        case .noRelease: return lang.t(.updNoRelease)
        case .http(let code): return lang.t(.updHTTP, String(code))
        case .badResponse: return lang.t(.updBadResponse)
        case .prerelease: return lang.t(.updPrerelease)
        case .unrecognizedTag(let tag): return lang.t(.updBadTag, tag)
        case .untrustedPage: return lang.t(.updUntrusted)
        case .currentVersionUnknown: return lang.t(.updUnknownCurrent)
        }
    }

    private func downloadFailureText(_ failure: UpdateDownload.Failure) -> String {
        switch failure {
        case .offline: return lang.t(.updOffline)
        case .timeout: return lang.t(.updTimeout)
        case .network(let code): return lang.t(.updNetwork, String(code))
        case .redirectRefused: return lang.t(.updRedirect)
        case .http(let code): return lang.t(.updHTTP, String(code))
        case .sizeMismatch: return lang.t(.updSizeMismatch)
        case .checksumMismatch: return lang.t(.updChecksumMismatch)
        case .disk(let text): return lang.t(.updDisk, text)
        case .cancelled: return lang.t(.updDownloadCancelled)
        }
    }

    private func backupFailureText(_ failure: AppBackup.Failure) -> String {
        switch failure {
        case .notAnApp: return lang.t(.updBackupNotApp)
        case .tool(let status): return "ditto \(status)"
        case .disk(let text): return text
        }
    }
}
