import CryptoKit
import Foundation

/// A Mac game's cloud saves as the engine reads them (#499), and what its last session's log says about the sync.
///
/// Where the folder comes from, in dm/mac/launcher.c's order (docs/frontends.md, "The cloud saves folder"): the first
/// `DM_SAVE_SYNC` line of `~/Library/Application Support/nxnative/<title ID>/env.txt`, then of the app's own
/// `Contents/Resources/dm/env.txt`, then `cloudSaves.folder` in the app's preferences domain. `icloud` is iCloud Drive ›
/// nxnative Saves, `0` or an empty value is off. The save is `<folder>/<TITLE ID>/save.dmsync`, or `<folder>/save.dmsync` for a
/// folder that is already the game's own (dm/host/save_sync.c, cloud_file).
package enum CloudSaveSync {
    package static let key = "DM_SAVE_SYNC"
    /// The key in the app's preferences domain (dm/mac/launcher.c, cloud_saves_folder).
    package static let preferenceKey = "cloudSaves.folder"
    package static let icloudFolder = "nxnative Saves"
    package static let altIcloudFolder = "NX Save data"

    package enum SyncResult: Equatable {
        case upToDate
        case downloaded(Date)
        case uploaded(Date)
        case noCloudSave
        case failed(String)
    }

    /// Where the folder that counts was set.
    package enum Source: Equatable { case playerEnv, appEnv, preference, none }

    /// The folder setting that counts, as the engine resolves it.
    package struct Setting: Equatable {
        package var source: Source
        /// The value as written (`icloud`, a path, `0`), nil when nothing sets it.
        package var value: String?
        /// The folder it means, nil when cloud saves are off.
        package var folder: String?
        package init(source: Source, value: String?, folder: String?) { self.source = source; self.value = value; self.folder = folder }
        package var isOn: Bool { folder != nil }
    }

    /// The first `DM_SAVE_SYNC` value of an env.txt, read as launcher.c's env_file does: `KEY=VALUE` lines, `#` starts a comment,
    /// spaces around the key and at the end of the value are dropped, the first line for a key wins.
    package static func envValue(_ text: String) -> String? { envLine(text)?.value }

    private static func envLine(_ text: String) -> (index: Int, value: String, ending: String)? {
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex,
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = String(line[line.index(after: eq)...])
            var ending = ""
            while let last = value.last, last == "\r" || last == " " || last == "\t" { ending = String(last) + ending; value.removeLast() }
            return (i, value, ending)
        }
        return nil
    }

    /// The folder a value means: nil for off (`0`, empty), iCloud Drive › nxnative Saves (or NX Save data) for `icloud`, else the path as written
    /// without a trailing slash.
    package static func folder(for value: String?, home: String = NSHomeDirectory()) -> String? {
        guard let value, !value.isEmpty, value != "0" else { return nil }
        if value == "icloud" {
            let base = home + "/Library/Mobile Documents/com~apple~CloudDocs"
            if FileManager.default.fileExists(atPath: base + "/" + altIcloudFolder) {
                return base + "/" + altIcloudFolder
            }
            return base + "/" + icloudFolder
        }
        var path = (value as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    package static func unpack(dmsyncData data: Data, into dir: URL) throws {
        guard data.count >= 144 else {
            throw NSError(domain: "DMSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid save archive size"])
        }
        guard data.prefix(8) == Data("DMSYNC1\n".utf8) else {
            throw NSError(domain: "DMSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid save magic"])
        }
        let entryCount = data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
        var offset = 144
        let fm = FileManager.default
        for _ in 0..<entryCount {
            guard offset + 24 <= data.count else {
                throw NSError(domain: "DMSync", code: 3, userInfo: [NSLocalizedDescriptionKey: "Truncated entry header"])
            }
            let entryType = data[offset]
            let pl = Int(data.subdata(in: offset + 2..<offset + 4).withUnsafeBytes { $0.load(as: UInt16.self) })
            let gl = Int(data.subdata(in: offset + 4..<offset + 6).withUnsafeBytes { $0.load(as: UInt16.self) })
            let sz = Int(data.subdata(in: offset + 8..<offset + 16).withUnsafeBytes { $0.load(as: UInt64.self) })
            let mt = Int64(data.subdata(in: offset + 16..<offset + 24).withUnsafeBytes { $0.load(as: Int64.self) })
            offset += 24
            guard offset + pl + gl + sz <= data.count else {
                throw NSError(domain: "DMSync", code: 4, userInfo: [NSLocalizedDescriptionKey: "Truncated entry payload"])
            }
            guard let path = String(data: data.subdata(in: offset..<offset + pl), encoding: .utf8) else {
                throw NSError(domain: "DMSync", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid path"])
            }
            offset += pl + gl
            let fileData = data.subdata(in: offset..<offset + sz)
            offset += sz
            
            let destURL = dir.appendingPathComponent(path)
            if entryType == 1 {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else if entryType == 2 {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileData.write(to: destURL, options: .atomic)
                let date = Date(timeIntervalSince1970: TimeInterval(mt))
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: destURL.path)
            }
        }
    }

    package static func pack(from dir: URL, titleID: String) throws -> Data {
        let fm = FileManager.default
        var entries: [(path: String, isDir: Bool, data: Data, mtime: Int64)] = []
        for folder in ["save", "save_device"] {
            let folderURL = dir.appendingPathComponent(folder)
            guard fm.fileExists(atPath: folderURL.path) else { continue }
            guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { continue }
            for case let fileURL as URL in enumerator {
                let rel = fileURL.path.dropFirst(dir.path.count + (dir.path.hasSuffix("/") ? 0 : 1))
                let rv = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                let isDir = rv.isDirectory ?? false
                let mtime = Int64(rv.contentModificationDate?.timeIntervalSince1970 ?? 0)
                if isDir {
                    entries.append((String(rel), true, Data(), mtime))
                } else {
                    let d = try Data(contentsOf: fileURL)
                    entries.append((String(rel), false, d, mtime))
                }
            }
        }
        var data = Data()
        data.append(Data("DMSYNC1\n".utf8))
        var ver: UInt32 = 1
        data.append(Data(bytes: &ver, count: 4))
        var count = UInt32(entries.count)
        data.append(Data(bytes: &count, count: 4))
        data.append(Data(repeating: 0x30, count: 32))
        var saved = Int64(Date().timeIntervalSince1970)
        data.append(Data(bytes: &saved, count: 8))
        var titleBytes = [UInt8](repeating: 0, count: 24)
        for (i, b) in titleID.utf8.prefix(23).enumerated() { titleBytes[i] = b }
        data.append(Data(titleBytes))
        var devBytes = [UInt8](repeating: 0, count: 64)
        for (i, b) in "Mac".utf8.prefix(63).enumerated() { devBytes[i] = b }
        data.append(Data(devBytes))
        for entry in entries {
            var entHdr = Data(count: 24)
            entHdr[0] = entry.isDir ? 1 : 2
            var pl = UInt16(entry.path.utf8.count)
            entHdr.replaceSubrange(2..<4, with: Data(bytes: &pl, count: 2))
            var gl: UInt16 = 0
            entHdr.replaceSubrange(4..<6, with: Data(bytes: &gl, count: 2))
            var sz = UInt64(entry.data.count)
            entHdr.replaceSubrange(8..<16, with: Data(bytes: &sz, count: 8))
            var mt = entry.mtime
            entHdr.replaceSubrange(16..<24, with: Data(bytes: &mt, count: 8))
            data.append(entHdr)
            data.append(Data(entry.path.utf8))
            if !entry.isDir { data.append(entry.data) }
        }
        data.append(Data("DMSYNCE\n".utf8))
        let hash = SHA256.hash(data: data.subdata(in: 144..<data.count - 8))
        let hexHash = hash.map { String(format: "%02x", $0) }.joined().prefix(32)
        data.replaceSubrange(16..<48, with: Data(hexHash.utf8))
        return data
    }

    @discardableResult
    package static func syncNow(titleID: String, folder: String? = nil, home: String = NSHomeDirectory()) -> SyncResult {
        let fm = FileManager.default
        let resolvedFolder: String
        if let folder {
            resolvedFolder = folder
        } else {
            let base = home + "/Library/Mobile Documents/com~apple~CloudDocs"
            if fm.fileExists(atPath: base + "/" + altIcloudFolder) {
                resolvedFolder = base + "/" + altIcloudFolder
            } else {
                resolvedFolder = base + "/" + icloudFolder
            }
        }
        let localGameDir = URL(fileURLWithPath: home + "/Library/Application Support/nxnative/" + titleID.uppercased())
        let localSaveDir = localGameDir.appendingPathComponent("save")
        let cloudPath = saveFile(folder: resolvedFolder, titleID: titleID)
        let cloudURL = URL(fileURLWithPath: cloudPath)
        
        let cloudExists = fm.fileExists(atPath: cloudPath)
        let localExists = fm.fileExists(atPath: localSaveDir.path)
        
        let envURL = localGameDir.appendingPathComponent("env.txt")
        let curEnv = (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
        let newEnv = settingEnv(curEnv, to: "icloud")
        try? fm.createDirectory(at: localGameDir, withIntermediateDirectories: true)
        try? newEnv.write(to: envURL, atomically: true, encoding: .utf8)
        
        if !cloudExists && !localExists { return .noCloudSave }
        
        var cloudDate = Date.distantPast
        if cloudExists, let attrs = try? fm.attributesOfItem(atPath: cloudPath), let d = attrs[.modificationDate] as? Date {
            cloudDate = d
        }
        
        var localDate = Date.distantPast
        if localExists {
            if let enumerator = fm.enumerator(at: localSaveDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for case let fileURL as URL in enumerator {
                    if let d = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        if d > localDate { localDate = d }
                    }
                }
            }
        }
        
        if cloudExists && (!localExists || cloudDate.timeIntervalSince(localDate) > 2.0) {
            do {
                let data = try Data(contentsOf: cloudURL)
                if localExists {
                    let backupDir = localGameDir.appendingPathComponent("save-backups/save-\(Int(Date().timeIntervalSince1970))")
                    try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    try? fm.copyItem(at: localSaveDir, to: backupDir.appendingPathComponent("save"))
                }
                try unpack(dmsyncData: data, into: localGameDir)
                return .downloaded(cloudDate)
            } catch {
                return .failed(error.localizedDescription)
            }
        } else if localExists && (!cloudExists || localDate.timeIntervalSince(cloudDate) > 2.0) {
            do {
                let data = try pack(from: localGameDir, titleID: titleID)
                try fm.createDirectory(at: cloudURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cloudURL, options: .atomic)
                return .uploaded(localDate)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .upToDate
    }

    package static func syncAllGames(home: String = NSHomeDirectory()) -> [String: SyncResult] {
        let fm = FileManager.default
        var results: [String: SyncResult] = [:]
        let appSupport = home + "/Library/Application Support/nxnative"
        if let list = try? fm.contentsOfDirectory(atPath: appSupport) {
            for item in list {
                guard item.count == 16, UInt64(item, radix: 16) != nil else { continue }
                results[item] = syncNow(titleID: item, home: home)
            }
        }
        for folder in [altIcloudFolder, icloudFolder] {
            let cloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs/" + folder
            if let titles = try? fm.contentsOfDirectory(atPath: cloudRoot) {
                for item in titles {
                    guard item.count == 16, UInt64(item, radix: 16) != nil, results[item] == nil else { continue }
                    results[item] = syncNow(titleID: item, home: home)
                }
            }
        }
        return results
    }

    /// The setting that counts, from the two env.txt texts (nil when the file is missing) and the preference.
    package static func resolve(playerEnv: String?, appEnv: String?, preference: String?, home: String = NSHomeDirectory()) -> Setting {
        if let v = playerEnv.flatMap(envValue) { return Setting(source: .playerEnv, value: v, folder: folder(for: v, home: home)) }
        if let v = appEnv.flatMap(envValue) { return Setting(source: .appEnv, value: v, folder: folder(for: v, home: home)) }
        if let v = preference, !v.isEmpty { return Setting(source: .preference, value: v, folder: folder(for: v, home: home)) }
        return Setting(source: .none, value: nil, folder: nil)
    }

    /// `<folder>/<TITLE ID>/save.dmsync`, or `<folder>/save.dmsync` when the folder is the game's own.
    package static func saveFile(folder: String, titleID: String) -> String {
        let id = titleID.uppercased()
        return (folder as NSString).lastPathComponent.uppercased() == id ? folder + "/save.dmsync" : folder + "/" + id + "/save.dmsync"
    }

    /// The player's env.txt with its first `DM_SAVE_SYNC` line set to `value`, or the line added at the end when it has none.
    /// Comments and every other line stay as they are.
    package static func settingEnv(_ text: String?, to value: String) -> String {
        let text = text ?? ""
        var lines = text.components(separatedBy: "\n")
        if let line = envLine(text) {
            lines[line.index] = "\(key)=\(value)\(line.ending)"
            return lines.joined(separator: "\n")
        }
        let body = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return body + "\(key)=\(value)\n"
    }

    /// What the folder holds for the game: a notice before the first play, so a wrong folder shows (#490).
    package enum FolderCheck: Equatable { case missing, noSave, hasSave(Date?) }

    package static func check(folder: String, titleID: String, fm: FileManager = .default) -> FolderCheck {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return .missing }
        let file = saveFile(folder: folder, titleID: titleID)
        guard fm.fileExists(atPath: file) else { return .noSave }
        return .hasSave((try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date)
    }

    /// What the last session's log says about the sync: the last result of the `save sync:` lines (dm/host/save_sync.c).
    package enum LogState: Equatable {
        case off(String)              // "off: <why>"
        case inStep                   // the save here and the cloud's are the same
        case broughtIn(String)        // a newer save came from the cloud, from the device named
        case waitingToSend            // this device's save is newer and goes to the cloud, and no send followed in this log
        case sent(String)             // "sent: <n> files, saved <time>, to <file>": the part before ", to"
        case offline                  // the cloud's save could not be read in time: sent later
        case nothingYet               // no save here or in the cloud yet
        case failed(String)           // a [RED] line, its text
    }

    /// The state the log ends with, nil when the session did not sync (cloud saves off, or the game never mounted its save).
    package static func state(fromLog text: String) -> LogState? {
        var state: LogState?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let at = line.range(of: "save sync: ") else { continue }
            let message = String(line[at.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("[RED] save sync:") { state = .failed(message); continue }
            if message.hasPrefix("off: ") { state = .off(String(message.dropFirst(5))) }
            else if message.hasPrefix("sent: ") {
                let detail = message.dropFirst(6)
                state = .sent(String(detail.range(of: ", to ").map { detail[..<$0.lowerBound] } ?? detail))
            }
            else if message == "in step with the cloud" { state = .inStep }
            else if message.hasPrefix("brought in the cloud's save") {
                let from = message.range(of: "(from ").flatMap { r in message[r.upperBound...].range(of: ", saved ").map { String(message[r.upperBound..<$0.lowerBound]) } }
                state = .broughtIn(from ?? "")
            }
            else if message.hasPrefix("this device's save") && message.hasSuffix("it goes to the cloud") { state = .waitingToSend }
            else if message.hasSuffix("cannot be read now; sending later") || message.hasPrefix("the cloud's save did not come within") { state = .offline }
            else if message == "no save here or in the cloud yet" { state = .nothingYet }
        }
        return state
    }
}
