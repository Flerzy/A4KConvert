import Foundation
import UpscaleCore

/// Persists `JobDefaults` in `UserDefaults`.
///
/// This lives in the app rather than the core so `UpscaleCore` stays free of any
/// storage of its own. The output folder is stored as a plain path: the app is not
/// sandboxed, so it needs no security-scoped bookmark.
enum DefaultsStore {
    private enum Key {
        static let presetID = "defaults.presetID"
        static let scale = "defaults.scale"
        static let encoder = "defaults.encoder"
        static let quality = "defaults.quality"
        static let outputFolder = "defaults.outputFolder"
        static let autoSkipChapters = "defaults.autoSkipChapters"
    }

    /// Reads the stored defaults, using `JobDefaults.standard` for anything missing or
    /// no longer valid (a renamed preset, an encoder that has been dropped).
    static func load(from store: UserDefaults = .standard) -> JobDefaults {
        var defaults = JobDefaults.standard
        if let presetID = store.string(forKey: Key.presetID) {
            defaults.presetID = presetID
        }
        if store.object(forKey: Key.scale) != nil {
            defaults.scale = store.integer(forKey: Key.scale)
        }
        if let raw = store.string(forKey: Key.encoder), let encoder = VideoEncoder(rawValue: raw) {
            defaults.encoder = encoder
        }
        if store.object(forKey: Key.quality) != nil {
            defaults.quality = store.integer(forKey: Key.quality)
        }
        if let path = store.string(forKey: Key.outputFolder), !path.isEmpty {
            defaults.outputFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        if store.object(forKey: Key.autoSkipChapters) != nil {
            defaults.autoSkipChapters = store.bool(forKey: Key.autoSkipChapters)
        }
        // A stored scale of 0 (or any other nonsense) would make every new job invalid.
        if defaults.scale != 2, defaults.scale != 4 {
            defaults.scale = JobDefaults.standard.scale
        }
        return defaults
    }

    static func save(_ defaults: JobDefaults, to store: UserDefaults = .standard) {
        store.set(defaults.presetID, forKey: Key.presetID)
        store.set(defaults.scale, forKey: Key.scale)
        store.set(defaults.encoder.rawValue, forKey: Key.encoder)
        store.set(defaults.quality, forKey: Key.quality)
        store.set(defaults.outputFolder?.path, forKey: Key.outputFolder)
        store.set(defaults.autoSkipChapters, forKey: Key.autoSkipChapters)
    }
}
