import Foundation

/// A player profile for per-user save isolation on iPhone, iPad, and Apple TV 4K.
/// The built-in `"default"` profile stores saves in `<game>/save`; custom profiles use `<game>/profiles/<id>/save`.
public struct SaveProfile: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SaveProfileValidation {
    private static let maxIDLength = 32

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIDLength else { return false }
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first, isASCIIAlphaNum(first) else { return false }
        return scalars.dropFirst().allSatisfy { isASCIIAlphaNum($0) || $0 == "_" || $0 == "-" }
    }

    public static func normalizeID(from rawName: String, existing: Set<String> = []) -> String {
        let folded = rawName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var slug = ""
        var prevDash = false
        for scalar in folded.unicodeScalars {
            if isASCIIAlphaNum(scalar) {
                slug.unicodeScalars.append(scalar)
                prevDash = false
            } else if !slug.isEmpty && !prevDash {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.hasSuffix("-") || slug.hasSuffix("_") { slug.removeLast() }
        var base = String(slug.prefix(28))
        while base.hasSuffix("-") || base.hasSuffix("_") { base.removeLast() }
        if base.isEmpty || base == ShellSettingsStore.defaultProfileID {
            base = "player"
        }
        if !existing.contains(base) && base != ShellSettingsStore.defaultProfileID {
            return base
        }
        var suffix = 2
        while true {
            let tag = "-\(suffix)"
            let clipped = String(base.prefix(maxIDLength - tag.count))
            let candidate = clipped + tag
            if !existing.contains(candidate) && candidate != ShellSettingsStore.defaultProfileID {
                return candidate
            }
            suffix += 1
        }
    }

    private static func isASCIIAlphaNum(_ s: UnicodeScalar) -> Bool {
        (s.value >= 48 && s.value <= 57) || (s.value >= 97 && s.value <= 122)
    }
}

/// The shell-level settings, one suite shared by every game: the game-data folder, the cloud-saves folder,
/// the default performance HUD and the touch controls. A game's own settings and bookmarks win over these, and
/// these win over the built-in defaults (ShellSettingsStore priority: game > shell > built-in).
public final class ShellSettingsStore: @unchecked Sendable {
    public static let padMapKey = "padMap"
    public static let suiteName = "shell-settings"
    public static let dataFolderKey = "globalDataBookmark"
    public static let cloudSavesKey = "globalCloudSavesBookmark"
    public static let performanceHUDKey = "performanceHUD"       // true/false; a game's own row wins when set
    public static let dataFolderNameKey = "globalDataFolderName"
    public static let cloudSavesNameKey = "globalCloudSavesFolderName"
    public static let touchSizeKey = "touchSize"                 // small, medium or large: DM_TOUCH_SIZE for every game
    /// The touch controls' sizes, as the engine reads DM_TOUCH_SIZE. Medium is the built-in size and is never stored.
    public static let touchSizes = ["small", "medium", "large"]
    public static let touchStickKey = "touchStick"               // corner, higher or inward: DM_TOUCH_STICK for every game
    /// Where the left stick sits, as the engine reads DM_TOUCH_STICK. The corner is the built-in place and is never stored.
    public static let touchStickPlaces = ["corner", "higher", "inward"]
    public static let touchModeKey = "touchMode" // 2d/3d, separate from saved positions
    public static let touchLayoutKey = "touchLayout"             // the player's arrangement: DM_TOUCH_LAYOUT for every game
    public static let saveBridgeURLKey = "saveBridgeURL"
    public static let saveBridgeTokenKey = "saveBridgeToken"
    public static let defaultProfileID = "default"
    public static let saveProfilesKey = "saveProfiles"
    public static let activeSaveProfileKey = "activeSaveProfile"
    public static let defaultProfileNameKey = "defaultProfileName"

    /// The store the app reads and writes. Tests and previews swap it.
    nonisolated(unsafe) public static var current = ShellSettingsStore()

    /// The suite itself, so the host keeps the folder bookmarks in it with its `BookmarkStore`.
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: ShellSettingsStore.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public var dataBookmark: Data? { defaults.data(forKey: Self.dataFolderKey) }
    public var cloudSavesBookmark: Data? { defaults.data(forKey: Self.cloudSavesKey) }
    /// The folders' names for the page, written by the host when the player picks them.
    public var dataFolderName: String? { defaults.string(forKey: Self.dataFolderNameKey) }
    public var cloudSavesFolderName: String? { defaults.string(forKey: Self.cloudSavesNameKey) }
    public var performanceHUD: Bool? {   // nil: no shell-level choice, the game's own row decides
        defaults.object(forKey: Self.performanceHUDKey) as? Bool
    }

    public func storeDataFolderName(_ name: String) { defaults.set(name, forKey: Self.dataFolderNameKey) }
    public func storeCloudSavesFolderName(_ name: String) { defaults.set(name, forKey: Self.cloudSavesNameKey) }
    public func clearDataFolderName() { defaults.removeObject(forKey: Self.dataFolderNameKey) }
    public func clearCloudSavesFolderName() { defaults.removeObject(forKey: Self.cloudSavesNameKey) }
    public func storePerformanceHUD(_ on: Bool) { defaults.set(on, forKey: Self.performanceHUDKey) }

    public var saveBridgeURL: String? {
        guard let v = defaults.string(forKey: Self.saveBridgeURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    public var saveBridgeToken: String? {
        guard let v = defaults.string(forKey: Self.saveBridgeTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    public func storeSaveBridgeURL(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.saveBridgeURLKey) }
        else { defaults.set(trimmed, forKey: Self.saveBridgeURLKey) }
    }
    public func storeSaveBridgeToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.saveBridgeTokenKey) }
        else { defaults.set(trimmed, forKey: Self.saveBridgeTokenKey) }
    }
    public func clearSaveBridge() {
        defaults.removeObject(forKey: Self.saveBridgeURLKey)
        defaults.removeObject(forKey: Self.saveBridgeTokenKey)
    }

    public var defaultProfileName: String? {
        guard let raw = defaults.string(forKey: Self.defaultProfileNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    public func storeDefaultProfileName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.defaultProfileNameKey) }
        else { defaults.set(trimmed, forKey: Self.defaultProfileNameKey) }
    }

    public var customSaveProfiles: [SaveProfile] {
        guard let json = defaults.string(forKey: Self.saveProfilesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SaveProfile].self, from: data) else {
            return []
        }
        return Self.sanitizeCustomProfiles(decoded)
    }

    public func storeCustomSaveProfiles(_ profiles: [SaveProfile]) {
        let sanitized = Self.sanitizeCustomProfiles(profiles)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: Self.saveProfilesKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(sanitized), let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: Self.saveProfilesKey)
        }
    }

    public func saveProfiles(defaultName: String? = nil) -> [SaveProfile] {
        let resolvedDefault = defaultProfileName ?? defaultName ?? ShellStrings.text("Default")
        return [SaveProfile(id: Self.defaultProfileID, name: resolvedDefault)] + customSaveProfiles
    }

    public var activeSaveProfileID: String {
        let saved = defaults.string(forKey: Self.activeSaveProfileKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if saved.isEmpty || saved == Self.defaultProfileID { return Self.defaultProfileID }
        return customSaveProfiles.contains { $0.id == saved } ? saved : Self.defaultProfileID
    }

    public func storeActiveSaveProfileID(_ id: String) {
        if id == Self.defaultProfileID || customSaveProfiles.contains(where: { $0.id == id }) {
            defaults.set(id, forKey: Self.activeSaveProfileKey)
        } else {
            defaults.set(Self.defaultProfileID, forKey: Self.activeSaveProfileKey)
        }
    }

    public func activeSaveProfile(defaultName: String? = nil) -> SaveProfile {
        let list = saveProfiles(defaultName: defaultName)
        let activeID = activeSaveProfileID
        return list.first { $0.id == activeID } ?? list[0]
    }

    @discardableResult
    public func addSaveProfile(name: String) -> SaveProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var current = customSaveProfiles
        let existingIDs = Set(current.map(\.id))
        let id = SaveProfileValidation.normalizeID(from: trimmed, existing: existingIDs)
        let profile = SaveProfile(id: id, name: trimmed)
        current.append(profile)
        storeCustomSaveProfiles(current)
        return profile
    }

    public func removeSaveProfile(id: String) {
        guard id != Self.defaultProfileID else { return }
        var current = customSaveProfiles
        current.removeAll { $0.id == id }
        storeCustomSaveProfiles(current)
        if activeSaveProfileID == id {
            storeActiveSaveProfileID(Self.defaultProfileID)
        }
    }

    /// Seeds profiles from embedded `DMSaveProfiles` JSON in Info.plist without discarding extra local profiles.
    public func seedSaveProfiles(fromJSON json: String?) {
        guard let json = json?.trimmingCharacters(in: .whitespacesAndNewlines), !json.isEmpty,
              let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode([SaveProfile].self, from: data) else {
            return
        }
        _ = mergeIncomingProfiles(incoming)
    }

    /// Merges profiles fetched from the Mac bridge (`[{"id","name"}]`) and reports whether anything changed.
    @discardableResult
    public func mergeIncomingProfiles(_ incoming: [SaveProfile]) -> Bool {
        var changed = false
        for entry in incoming where entry.id == Self.defaultProfileID {
            let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != defaultProfileName {
                storeDefaultProfileName(trimmed)
                changed = true
            }
        }
        var current = customSaveProfiles
        for entry in incoming where entry.id != Self.defaultProfileID {
            let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, SaveProfileValidation.isValidID(entry.id) else { continue }
            if let idx = current.firstIndex(where: { $0.id == entry.id }) {
                if current[idx].name != trimmed {
                    current[idx].name = trimmed
                    changed = true
                }
            } else {
                current.append(SaveProfile(id: entry.id, name: trimmed))
                changed = true
            }
        }
        if changed {
            storeCustomSaveProfiles(current)
        }
        return changed
    }

    private static func sanitizeCustomProfiles(_ profiles: [SaveProfile]) -> [SaveProfile] {
        var seen = Set<String>([defaultProfileID])
        var result: [SaveProfile] = []
        for entry in profiles {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, SaveProfileValidation.isValidID(entry.id), !seen.contains(entry.id) else {
                continue
            }
            seen.insert(entry.id)
            result.append(SaveProfile(id: entry.id, name: trimmedName))
        }
        return result
    }

    /// The touch controls' size for every game: small, medium (the built-in size) or large.
    public var touchSize: String {
        let value = defaults.string(forKey: Self.touchSizeKey) ?? "medium"
        return Self.touchSizes.contains(value) ? value : "medium"
    }
    public func storeTouchSize(_ size: String) {
        guard Self.touchSizes.contains(size) else { return }
        if size == "medium" { defaults.removeObject(forKey: Self.touchSizeKey) } else { defaults.set(size, forKey: Self.touchSizeKey) }
    }

    /// Unset keeps each game's original starting layout.
    public var touchMode: String { defaults.string(forKey: Self.touchModeKey) == "2d" ? "2d" : "3d" }
    public func storeTouchMode(_ mode: String) {
        guard mode == "2d" || mode == "3d" else { return }
        defaults.set(mode, forKey: Self.touchModeKey)
    }

    /// Where the left stick sits in every game: in the corner (the built-in place), higher, or further in.
    public var touchStick: String {
        let value = defaults.string(forKey: Self.touchStickKey) ?? "corner"
        return Self.touchStickPlaces.contains(value) ? value : "corner"
    }
    public func storeTouchStick(_ place: String) {
        guard Self.touchStickPlaces.contains(place) else { return }
        if place == "corner" { defaults.removeObject(forKey: Self.touchStickKey) } else { defaults.set(place, forKey: Self.touchStickKey) }
    }

    /// The player's arrangement of the touch controls for every game (#414): stored as the value the engine reads, so what the
    /// settings show is what a game gets. A stored value the engine would ignore reads as the built-in layout.
    public var touchLayout: TouchLayout {
        defaults.string(forKey: Self.touchLayoutKey).flatMap { TouchLayout(encoded: $0) } ?? TouchLayout()
    }
    public func storeTouchLayout(_ layout: TouchLayout) {
        if layout.isEmpty { defaults.removeObject(forKey: Self.touchLayoutKey) } else { defaults.set(layout.encoded, forKey: Self.touchLayoutKey) }
    }
    /// Every control of one layout back to its built-in place.
    public func resetTouchLayout(_ kind: TouchLayout.Kind) {
        var layout = touchLayout
        layout.reset(kind)
        storeTouchLayout(layout)
    }

    public var padMap: PadMap { PadMap(defaults.dictionary(forKey: Self.padMapKey) as? [String: String] ?? [:]) }
    public func setPadButton(_ button: String, to output: String) {
        var map = padMap
        map.set(button, to: output)
        defaults.set(map.entries, forKey: Self.padMapKey)
    }
    public func setPadSwapAB(_ on: Bool) {
        var map = padMap
        map.setSwapAB(on)
        defaults.set(map.entries, forKey: Self.padMapKey)
    }
    public func resetPadMap() { defaults.removeObject(forKey: Self.padMapKey) }

    /// DM_PAD_MAP is deliberately excluded. The host merges it per button at launch.
    /// The shell's value for each `DM_*` switch a game's own settings leave alone.
    public var gameDefaults: [String: String] {
        var values = performanceHUD.map { ["DM_METAL_HUD": $0 ? "1" : "0"] } ?? [:]
        if touchSize != "medium" { values["DM_TOUCH_SIZE"] = touchSize }
        if touchStick != "corner" { values["DM_TOUCH_STICK"] = touchStick }
        if let mode = defaults.string(forKey: Self.touchModeKey), mode == "2d" || mode == "3d" {
            values["DM_PROF_PAD_LAYOUT"] = mode == "3d" ? "1" : "0"
        }
        let layout = touchLayout.encoded
        if !layout.isEmpty { values["DM_TOUCH_LAYOUT"] = layout }
        return values
    }
}
