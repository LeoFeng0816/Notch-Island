import Foundation
import CoreLocation
import AppKit

/// One-shot, coarse "current location" for the weather widget.
///
/// - The `CLLocationManager` is created lazily, only when the user presses
///   "Use Current Location" in Settings, so nothing is requested at launch.
/// - Reduced accuracy is requested and the result is rounded to
///   `roundingStep` degrees (~11 km) before it is stored or sent to Open-Meteo.
/// - No continuous tracking: each request is a single `requestLocation()`.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Failure: Error, Equatable {
        case denied, restricted, servicesOff, unavailable, network, timeout
        var messageKey: L10nKey {
            switch self {
            case .denied: return .locDenied
            case .restricted: return .locRestricted
            case .servicesOff: return .locServicesOff
            case .unavailable: return .locUnavailable
            case .network: return .locNetwork
            case .timeout: return .locTimeout
            }
        }
        /// Failures the user fixes in System Settings.
        var opensSettings: Bool { self == .denied || self == .servicesOff }
    }

    nonisolated static let roundingStep = 0.1
    static let timeout: Duration = .seconds(20)

    @Published private(set) var isLocating = false
    @Published private(set) var lastFailure: Failure?

    private var manager: CLLocationManager?
    /// False until the user first asks for their location (nothing is created at launch).
    var hasLocationManager: Bool { manager != nil }
    private var continuation: CheckedContinuation<Result<CLLocationCoordinate2D, Failure>, Never>?

    /// Status without creating a manager or prompting.
    static var authorizationStatus: CLAuthorizationStatus { CLLocationManager().authorizationStatus }

    /// Rounds to a coarse grid; never keeps the precise fix.
    nonisolated static func coarse(_ coordinate: CLLocationCoordinate2D, step: Double = roundingStep) -> CLLocationCoordinate2D {
        func round(_ value: Double) -> Double { (value / step).rounded() * step }
        return CLLocationCoordinate2D(latitude: (round(coordinate.latitude) * 1000).rounded() / 1000,
                                      longitude: (round(coordinate.longitude) * 1000).rounded() / 1000)
    }

    nonisolated static func failure(for status: CLAuthorizationStatus) -> Failure? {
        switch status {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return nil
        }
    }

    /// `.authorizedAlways` (macOS's usual grant) or `.authorizedWhenInUse`.
    nonisolated static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status.rawValue >= CLAuthorizationStatus.authorizedAlways.rawValue
    }

    nonisolated static func failure(for error: Error) -> Failure {
        guard let error = error as? CLError else { return .unavailable }
        switch error.code {
        case .denied: return .denied
        case .network: return .network
        default: return .unavailable
        }
    }

    /// Asks for permission if needed (system prompt) and returns a coarse coordinate.
    func requestCoarseLocation() async -> Result<CLLocationCoordinate2D, Failure> {
        guard continuation == nil else { return .failure(.unavailable) }
        // `locationServicesEnabled()` can block; check it off the main thread.
        let servicesOn = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard servicesOn else { return finish(.failure(.servicesOff)) }
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        if let failure = Self.failure(for: manager.authorizationStatus) { return finish(.failure(failure)) }
        isLocating = true
        lastFailure = nil
        requestID += 1
        let id = requestID
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization() // delegate continues once the user answers
            } else {
                manager.requestLocation()
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                // Only time out the request that started this timer.
                guard let self, self.requestID == id else { return }
                self.resume(.failure(.timeout))
            }
        }
    }

    private var requestID = 0

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>) -> Result<CLLocationCoordinate2D, Failure> {
        isLocating = false
        if case .failure(let failure) = result { lastFailure = failure }
        return result
    }

    private func resume(_ result: Result<CLLocationCoordinate2D, Failure>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: finish(result))
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self, self.continuation != nil else { return }
            if let failure = Self.failure(for: status) {
                self.resume(.failure(failure))
            } else if Self.isAuthorized(status) {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let rounded = Self.coarse(coordinate)
        Task { @MainActor [weak self] in self?.resume(.success(rounded)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; requestLocation reports it once and gives up.
        let failure = Self.failure(for: error)
        Task { @MainActor [weak self] in self?.resume(.failure(failure)) }
    }
}
