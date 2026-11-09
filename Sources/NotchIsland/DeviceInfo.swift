import Foundation

/// Hardware model as reported by the kernel (`hw.model`, e.g. "Mac17,3").
///
/// Used only for reporting/diagnostics. Layout never depends on it: the notch
/// is measured from the screen itself (see `NotchGeometry`), so unknown or
/// future models work as long as macOS reports their safe area.
struct DeviceInfo: Equatable {
    var modelIdentifier: String
    var firstLaunch: Date
    /// True when this launch is the first one on this model (new install or migrated Mac).
    var isFirstLaunchOnModel: Bool

    private static let modelKey = "NotchIsland.device.model"
    private static let firstLaunchKey = "NotchIsland.device.firstLaunch"

    /// Records the model on first launch (or when the preferences moved to another Mac).
    static func detect(defaults: UserDefaults = .standard,
                       model: String = DeviceInfo.currentModelIdentifier(),
                       now: Date = Date()) -> DeviceInfo {
        let stored = defaults.string(forKey: modelKey)
        let isNew = stored != model
        if isNew {
            defaults.set(model, forKey: modelKey)
            defaults.set(now.timeIntervalSince1970, forKey: firstLaunchKey)
        }
        let first = defaults.double(forKey: firstLaunchKey)
        return DeviceInfo(modelIdentifier: model,
                          firstLaunch: first > 0 ? Date(timeIntervalSince1970: first) : now,
                          isFirstLaunchOnModel: isNew)
    }

    static func currentModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }
}
