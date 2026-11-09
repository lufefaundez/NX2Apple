import Foundation

/// What a build makes. The launcher has two targets: a Mac app, and the game's framework in the one shared app on an
/// iPhone or iPad. The target is stored as text in the settings and in the library.
package enum BuildTarget {
    package static let mac = "mac-app"
    package static let ios = "ios"
    package static let tvos = "tvos"

    /// Normalizes the target string: "mac-app", "tvos" (or "appletvos"), else "ios".
    package static func normalized(_ value: String?) -> String {
        if value == mac { return mac }
        if value == tvos || value == "appletvos" { return tvos }
        return ios
    }

    /// The saved choice. An old value is stored again in its new form.
    package static func saved(_ defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: "buildTarget")
        let value = normalized(stored)
        if stored != nil, stored != value { defaults.set(value, forKey: "buildTarget") }
        return value
    }
}
