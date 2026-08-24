import Foundation

enum AppGroup {
    static let id = "group.manas.projects.AuroraTracker"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }

    enum Key {
        static let locationLat = "cachedLocationLat"
        static let locationLon = "cachedLocationLon"
    }
}

/// Coarse location shared between the app and widget via the App Group.
/// Rounded to the nearest degree — matches Ovation's 1° grid resolution,
/// so nothing more precise than the feature needs is ever persisted.
enum CachedLocation {
    static func save(lat: Double, lon: Double) {
        let defaults = AppGroup.defaults
        defaults.set(lat.rounded(), forKey: AppGroup.Key.locationLat)
        defaults.set(lon.rounded(), forKey: AppGroup.Key.locationLon)
    }

    static func load() -> (lat: Double, lon: Double)? {
        let defaults = AppGroup.defaults
        guard defaults.object(forKey: AppGroup.Key.locationLat) != nil,
              defaults.object(forKey: AppGroup.Key.locationLon) != nil else {
            return nil
        }
        return (defaults.double(forKey: AppGroup.Key.locationLat),
                defaults.double(forKey: AppGroup.Key.locationLon))
    }
}
