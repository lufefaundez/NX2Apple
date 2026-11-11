import Foundation

/// A player profile recognized by both NX2Apple on Mac (`SaveSyncBridge`) and NX2Apple on iOS / Apple TV.
/// `folderPath` stays local to the Mac (never included in `/saves/profiles.json` or embedded Info.plist).
package struct SaveBridgeProfile: Codable, Equatable, Identifiable, Sendable {
    package var id: String
    package var name: String
    package var folderPath: String?

    package init(id: String, name: String, folderPath: String? = nil) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
    }
}

package enum SaveProfileValidation {
    private static let maxIDLength = 32

    package static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIDLength else { return false }
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first, isASCIIAlphaNum(first) else { return false }
        return scalars.dropFirst().allSatisfy { isASCIIAlphaNum($0) || $0 == "_" || $0 == "-" }
    }

    package static func normalizeID(from rawName: String, existing: Set<String> = []) -> String {
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
        if base.isEmpty || base == SaveBridgeProfileStore.defaultProfileID {
            base = "player"
        }
        if !existing.contains(base) && base != SaveBridgeProfileStore.defaultProfileID {
            return base
        }
        var suffix = 2
        while true {
            let tag = "-\(suffix)"
            let clipped = String(base.prefix(maxIDLength - tag.count))
            let candidate = clipped + tag
            if !existing.contains(candidate) && candidate != SaveBridgeProfileStore.defaultProfileID {
                return candidate
            }
            suffix += 1
        }
    }

    private static func isASCIIAlphaNum(_ s: UnicodeScalar) -> Bool {
        (s.value >= 48 && s.value <= 57) || (s.value >= 97 && s.value <= 122)
    }
}

package enum SaveBridgeProfileStore {
    package static let defaultProfileID = "default"
    package static let profilesKey = "saveBridgeProfiles"
    package static let defaultNameKey = "saveBridgeDefaultProfileName"
    package static let macActiveKey = "saveBridgeActiveMacProfile"

    package static func defaultProfileName(fallback: String = "Default", defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: defaultNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? fallback : raw
    }

    package static func setDefaultProfileName(_ name: String, defaults: UserDefaults = .standard) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultNameKey)
        } else {
            defaults.set(trimmed, forKey: defaultNameKey)
        }
    }

    package static func customProfiles(defaults: UserDefaults = .standard) -> [SaveBridgeProfile] {
        guard let json = defaults.string(forKey: profilesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SaveBridgeProfile].self, from: data) else {
            return []
        }
        var seen = Set<String>([defaultProfileID])
        var result: [SaveBridgeProfile] = []
        for entry in decoded {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  SaveProfileValidation.isValidID(entry.id),
                  !seen.contains(entry.id) else { continue }
            seen.insert(entry.id)
            let cleanedFolder = entry.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(SaveBridgeProfile(id: entry.id, name: trimmedName,
                                            folderPath: (cleanedFolder?.isEmpty == false) ? cleanedFolder : nil))
        }
        return result
    }

    package static func saveCustomProfiles(_ profiles: [SaveBridgeProfile], defaults: UserDefaults = .standard) {
        var seen = Set<String>([defaultProfileID])
        var sanitized: [SaveBridgeProfile] = []
        for entry in profiles {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  SaveProfileValidation.isValidID(entry.id),
                  !seen.contains(entry.id) else { continue }
            seen.insert(entry.id)
            let cleanedFolder = entry.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            sanitized.append(SaveBridgeProfile(id: entry.id, name: trimmedName,
                                               folderPath: (cleanedFolder?.isEmpty == false) ? cleanedFolder : nil))
        }
        if sanitized.isEmpty {
            defaults.removeObject(forKey: profilesKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(sanitized), let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: profilesKey)
        }
    }

    package static func allProfiles(fallbackDefaultName: String = "Default", home: String = NSHomeDirectory(),
                                    defaults: UserDefaults = .standard) -> [SaveBridgeProfile] {
        let def = SaveBridgeProfile(id: defaultProfileID,
                                    name: defaultProfileName(fallback: fallbackDefaultName, defaults: defaults),
                                    folderPath: SaveSyncBridge.savesRoot(home: home).path)
        return [def] + customProfiles(defaults: defaults)
    }

    @discardableResult
    package static func addProfile(name: String, folderPath: String? = nil,
                                   defaults: UserDefaults = .standard) -> SaveBridgeProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        var current = customProfiles(defaults: defaults)
        let existingIDs = Set(current.map(\.id))
        let id = SaveProfileValidation.normalizeID(from: trimmedName, existing: existingIDs)
        let cleanedFolder = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SaveBridgeProfile(id: id, name: trimmedName,
                                        folderPath: (cleanedFolder?.isEmpty == false) ? cleanedFolder : nil)
        current.append(profile)
        saveCustomProfiles(current, defaults: defaults)
        return profile
    }

    package static func removeProfile(id: String, defaults: UserDefaults = .standard) {
        guard id != defaultProfileID else { return }
        var current = customProfiles(defaults: defaults)
        current.removeAll { $0.id == id }
        saveCustomProfiles(current, defaults: defaults)
        if defaults.string(forKey: macActiveKey) == id {
            defaults.set(defaultProfileID, forKey: macActiveKey)
        }
    }

    package static func setFolderPath(id: String, path: String?, defaults: UserDefaults = .standard) {
        guard id != defaultProfileID else { return }
        var current = customProfiles(defaults: defaults)
        guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        current[idx].folderPath = (trimmed?.isEmpty == false) ? trimmed : nil
        saveCustomProfiles(current, defaults: defaults)
    }

    package static func activeMacProfileID(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: macActiveKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if saved.isEmpty || saved == defaultProfileID { return defaultProfileID }
        return customProfiles(defaults: defaults).contains { $0.id == saved } ? saved : defaultProfileID
    }

    package static func setActiveMacProfileID(_ id: String, defaults: UserDefaults = .standard) {
        if id == defaultProfileID || customProfiles(defaults: defaults).contains(where: { $0.id == id }) {
            defaults.set(id, forKey: macActiveKey)
        } else {
            defaults.set(defaultProfileID, forKey: macActiveKey)
        }
    }

    package static func resolvedFolder(for profileID: String, home: String = NSHomeDirectory(),
                                       defaults: UserDefaults = .standard, baseRoot: URL? = nil) -> URL {
        let root = baseRoot ?? SaveSyncBridge.savesRoot(home: home)
        guard profileID != defaultProfileID else { return root }
        if let custom = customProfiles(defaults: defaults).first(where: { $0.id == profileID }),
           let folder = custom.folderPath, !folder.isEmpty {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        return root.appendingPathComponent("profiles/\(profileID)", isDirectory: true)
    }

    package static func publicProfiles(fallbackDefaultName: String = "Default",
                                       defaults: UserDefaults = .standard) -> [SaveBridgeProfile] {
        allProfiles(fallbackDefaultName: fallbackDefaultName, defaults: defaults)
            .map { SaveBridgeProfile(id: $0.id, name: $0.name, folderPath: nil) }
    }

    package static func encodedJSON(fallbackDefaultName: String = "Default",
                                    defaults: UserDefaults = .standard) -> String? {
        let profiles = publicProfiles(fallbackDefaultName: fallbackDefaultName, defaults: defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(profiles) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
