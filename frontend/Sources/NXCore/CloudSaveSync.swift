import CryptoKit
import Darwin
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
    package static let guestXattrName = "org.d2rmobile.guest-name"
    private static let archiveFolders = ["save", "save_device"]
    private static let magic = Data("DMSYNC1\n".utf8)
    private static let endMarker = Data("DMSYNCE\n".utf8)
    private static let keepBackups = 10

    package enum SyncResult: Equatable {
        case upToDate
        case downloaded(Date)
        case uploaded(Date)
        case noCloudSave
        case failed(String)
    }

    package struct ArchiveMeta: Equatable, Sendable {
        package var hash: String
        package var saved: Int64
        package var title: String
        package var device: String
        package var files: Int

        package init(hash: String = "", saved: Int64 = 0, title: String = "", device: String = "", files: Int = 0) {
            self.hash = hash
            self.saved = saved
            self.title = title
            self.device = device
            self.files = files
        }
    }

    package enum MergeDecision: Equatable {
        case keep, pull, push
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
        if value == "icloud" { return defaultICloudFolder(home: home) }
        var path = (value as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    package static func defaultICloudFolder(home: String = NSHomeDirectory()) -> String {
        let base = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: base + "/" + altIcloudFolder) {
            return base + "/" + altIcloudFolder
        }
        return base + "/" + icloudFolder
    }

    // MARK: - .dmsync binary codec (exact parity with dm/host/save_sync.c)

    private struct WalkEntry {
        let relativePath: String
        let isDirectory: Bool
        let guestName: Data
        let mtime: Int64
        let data: Data
    }

    private struct ParsedEntry {
        let relativePath: String
        let isDirectory: Bool
        let guestName: Data
        let mtime: Int64
        let payloadRange: Range<Int>
    }

    package static func deviceModel() -> String {
        var size = 0
        let name = "hw.model"
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(cString: buf)
        return model.isEmpty ? "Mac" : model
    }

    private static func hasSaveEntries(atPath dir: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return items.contains { $0 != ".DS_Store" }
    }

    private static func guestName(atPath path: String) -> Data {
        var buf = [UInt8](repeating: 0, count: 1024)
        let len = getxattr(path, guestXattrName, &buf, buf.count, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return Data() }
        return Data(buf.prefix(len))
    }

    private static func setGuestName(_ guest: Data, atPath path: String) throws {
        guard !guest.isEmpty else { return }
        let rc = guest.withUnsafeBytes { raw in
            setxattr(path, guestXattrName, raw.baseAddress, guest.count, 0, XATTR_NOFOLLOW)
        }
        if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func walkSaveDirectory(absPath: String, relPath: String, into entries: inout [WalkEntry]) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: absPath)
            .filter { $0 != ".DS_Store" }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for name in names {
            let childAbs = absPath + "/" + name
            let childRel = relPath + "/" + name
            var st = stat()
            if lstat(childAbs, &st) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
            }
            let mode = st.st_mode & S_IFMT
            let mtime = Int64(st.st_mtimespec.tv_sec)
            let guest = guestName(atPath: childAbs)
            if mode == S_IFDIR {
                entries.append(WalkEntry(relativePath: childRel, isDirectory: true, guestName: guest, mtime: mtime, data: Data()))
                try walkSaveDirectory(absPath: childAbs, relPath: childRel, into: &entries)
            } else if mode == S_IFREG {
                let fileData = try Data(contentsOf: URL(fileURLWithPath: childAbs))
                entries.append(WalkEntry(relativePath: childRel, isDirectory: false, guestName: guest, mtime: mtime, data: fileData))
            }
        }
    }

    private static func isValidArchivePath(_ path: String) -> Bool {
        guard path.hasPrefix("save/") || path.hasPrefix("save_device/") else { return false }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[offset + i]) << (i * 8) }
        return value
    }

    private static func readCString(_ data: Data, in range: Range<Int>) -> String {
        let slice = data[range]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[..<end], as: UTF8.self)
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func entryHeader16(type: UInt8, pathLen: UInt16, guestLen: UInt16, size: UInt64) -> Data {
        var h = Data()
        h.reserveCapacity(16)
        h.append(type)
        h.append(0)
        appendLE(&h, pathLen)
        appendLE(&h, guestLen)
        appendLE(&h, UInt16(0))
        appendLE(&h, size)
        return h
    }

    private static func shortHexDigest(_ sha: inout SHA256) -> String {
        let digest = sha.finalize()
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    package static func scan(from dir: URL) throws -> ArchiveMeta {
        var entries: [WalkEntry] = []
        for folder in archiveFolders {
            let folderPath = dir.appendingPathComponent(folder).path
            if hasSaveEntries(atPath: folderPath) {
                try walkSaveDirectory(absPath: folderPath, relPath: folder, into: &entries)
            }
        }
        var sha = SHA256()
        var files = 0
        var saved: Int64 = 0
        for e in entries {
            let pathData = Data(e.relativePath.utf8)
            guard pathData.count <= Int(UInt16.max), e.guestName.count <= Int(UInt16.max) else {
                throw NSError(domain: "DMSync", code: 6, userInfo: [NSLocalizedDescriptionKey: "Path exceeds entry limit"])
            }
            let h16 = entryHeader16(type: e.isDirectory ? 1 : 2, pathLen: UInt16(pathData.count),
                                    guestLen: UInt16(e.guestName.count), size: e.isDirectory ? 0 : UInt64(e.data.count))
            sha.update(data: h16)
            sha.update(data: pathData)
            sha.update(data: e.guestName)
            if !e.isDirectory {
                sha.update(data: e.data)
                files += 1
                if e.mtime > saved { saved = e.mtime }
            }
        }
        let hash = files > 0 ? shortHexDigest(&sha) : ""
        return ArchiveMeta(hash: hash, saved: saved, title: "", device: "", files: files)
    }

    package static func pack(from dir: URL, titleID: String) throws -> Data {
        var entries: [WalkEntry] = []
        for folder in archiveFolders {
            let folderPath = dir.appendingPathComponent(folder).path
            if hasSaveEntries(atPath: folderPath) {
                try walkSaveDirectory(absPath: folderPath, relPath: folder, into: &entries)
            }
        }
        var sha = SHA256()
        var files = 0
        var saved: Int64 = 0
        var body = Data()
        for e in entries {
            let pathData = Data(e.relativePath.utf8)
            guard pathData.count <= Int(UInt16.max), e.guestName.count <= Int(UInt16.max) else {
                throw NSError(domain: "DMSync", code: 6, userInfo: [NSLocalizedDescriptionKey: "Path exceeds entry limit"])
            }
            let h16 = entryHeader16(type: e.isDirectory ? 1 : 2, pathLen: UInt16(pathData.count),
                                    guestLen: UInt16(e.guestName.count), size: e.isDirectory ? 0 : UInt64(e.data.count))
            sha.update(data: h16)
            sha.update(data: pathData)
            sha.update(data: e.guestName)
            body.append(h16)
            appendLE(&body, e.mtime)
            body.append(pathData)
            body.append(e.guestName)
            if !e.isDirectory {
                sha.update(data: e.data)
                body.append(e.data)
                files += 1
                if e.mtime > saved { saved = e.mtime }
            }
        }
        let hash = files > 0 ? shortHexDigest(&sha) : ""
        let upperTitle = titleID.uppercased()
        let device = deviceModel()

        var out = Data()
        out.reserveCapacity(144 + body.count + 8)
        out.append(magic)
        appendLE(&out, UInt32(1))
        appendLE(&out, UInt32(entries.count))
        var hashBytes = [UInt8](repeating: 0, count: 32)
        for (i, b) in hash.utf8.prefix(32).enumerated() { hashBytes[i] = b }
        out.append(contentsOf: hashBytes)
        appendLE(&out, saved)
        var titleBytes = [UInt8](repeating: 0, count: 24)
        for (i, b) in upperTitle.utf8.prefix(23).enumerated() { titleBytes[i] = b }
        out.append(contentsOf: titleBytes)
        var devBytes = [UInt8](repeating: 0, count: 64)
        for (i, b) in device.utf8.prefix(63).enumerated() { devBytes[i] = b }
        out.append(contentsOf: devBytes)
        out.append(body)
        out.append(endMarker)
        return out
    }

    private static func parseAndVerify(dmsyncData rawData: Data) throws -> (meta: ArchiveMeta, entries: [ParsedEntry]) {
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)
        guard data.count >= 144 + 8 else {
            throw NSError(domain: "DMSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid save archive size"])
        }
        guard data.prefix(8) == magic else {
            throw NSError(domain: "DMSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid save magic"])
        }
        let version = readUInt32LE(data, at: 8)
        guard version == 1 else {
            throw NSError(domain: "DMSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported save archive version \(version)"])
        }
        let entryCount = readUInt32LE(data, at: 12)
        let wantHash = readCString(data, in: 16..<48)
        let saved = Int64(bitPattern: readUInt64LE(data, at: 48))
        let title = readCString(data, in: 56..<80)
        let device = readCString(data, in: 80..<144)

        var offset = 144
        var sha = SHA256()
        var regularFiles = 0
        var parsed: [ParsedEntry] = []
        let limitOffset = data.count - 8

        for _ in 0..<entryCount {
            guard offset + 24 <= limitOffset else {
                throw NSError(domain: "DMSync", code: 3, userInfo: [NSLocalizedDescriptionKey: "Truncated entry header"])
            }
            let entryType = data[offset]
            let pl = Int(readUInt16LE(data, at: offset + 2))
            let gl = Int(readUInt16LE(data, at: offset + 4))
            let szU64 = readUInt64LE(data, at: offset + 8)
            let mt = Int64(bitPattern: readUInt64LE(data, at: offset + 16))
            guard (entryType == 1 || entryType == 2), pl > 0, pl < Int(PATH_MAX), gl <= 1024, !(entryType == 1 && szU64 != 0) else {
                throw NSError(domain: "DMSync", code: 5, userInfo: [NSLocalizedDescriptionKey: "Malformed archive entry"])
            }
            let header16 = data[offset..<offset + 16]
            offset += 24
            guard szU64 <= UInt64(limitOffset - offset), let sz = Int(exactly: szU64),
                  pl + gl <= limitOffset - offset - sz else {
                throw NSError(domain: "DMSync", code: 4, userInfo: [NSLocalizedDescriptionKey: "Truncated entry payload"])
            }
            let pathData = data[offset..<offset + pl]
            guard !pathData.contains(0), let path = String(data: pathData, encoding: .utf8), isValidArchivePath(path) else {
                throw NSError(domain: "DMSync", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid path in save archive"])
            }
            offset += pl
            let guestData = Data(data[offset..<offset + gl])
            offset += gl
            let payloadRange = offset..<offset + sz
            offset += sz

            sha.update(data: header16)
            sha.update(data: pathData)
            sha.update(data: guestData)
            if entryType == 2 {
                sha.update(data: data[payloadRange])
                regularFiles += 1
            }
            parsed.append(ParsedEntry(relativePath: path, isDirectory: entryType == 1, guestName: guestData, mtime: mt, payloadRange: payloadRange))
        }

        guard offset == limitOffset, data[offset..<offset + 8] == endMarker else {
            throw NSError(domain: "DMSync", code: 7, userInfo: [NSLocalizedDescriptionKey: "Truncated or invalid end marker"])
        }
        let hash = regularFiles > 0 ? shortHexDigest(&sha) : ""
        guard hash == wantHash else {
            throw NSError(domain: "DMSync", code: 8, userInfo: [NSLocalizedDescriptionKey: "Save archive checksum mismatch"])
        }
        return (ArchiveMeta(hash: hash, saved: saved, title: title, device: device, files: regularFiles), parsed)
    }

    package static func inspect(dmsyncData data: Data) throws -> ArchiveMeta {
        try parseAndVerify(dmsyncData: data).meta
    }

    @discardableResult
    package static func unpack(dmsyncData data: Data, into dir: URL) throws -> ArchiveMeta {
        let (meta, entries) = try parseAndVerify(dmsyncData: data)
        let fm = FileManager.default
        let rootPath = dir.standardizedFileURL.path
        for entry in entries {
            let destURL = dir.appendingPathComponent(entry.relativePath).standardizedFileURL
            guard destURL.path.hasPrefix(rootPath + "/") else {
                throw NSError(domain: "DMSync", code: 5, userInfo: [NSLocalizedDescriptionKey: "Path escapes destination"])
            }
            if entry.isDirectory {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                try setGuestName(entry.guestName, atPath: destURL.path)
            } else {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data[entry.payloadRange].write(to: destURL, options: .atomic)
                try setGuestName(entry.guestName, atPath: destURL.path)
                var tv = [timeval(tv_sec: Int(entry.mtime), tv_usec: 0), timeval(tv_sec: Int(entry.mtime), tv_usec: 0)]
                utimes(destURL.path, &tv)
            }
        }
        return meta
    }

    // MARK: - 3-way sync decision, .sync base, backups, coordinated I/O

    package static func decide(local: String, base: String, remote: String, localSaved: Int64, remoteSaved: Int64, bothChanged: inout Bool) -> MergeDecision {
        bothChanged = false
        if remote.isEmpty { return local.isEmpty ? .keep : .push }
        if local == remote { return .keep }
        if local.isEmpty { return .pull }
        if !base.isEmpty && local == base { return .pull }
        if !base.isEmpty && remote == base { return .push }
        bothChanged = true
        return remoteSaved > localSaved ? .pull : .push
    }

    private static func readBase(savePath: String) -> String {
        guard let text = try? String(contentsOfFile: savePath + ".sync", encoding: .utf8) else { return "" }
        var found = ""
        for line in text.components(separatedBy: "\n") where line.hasPrefix("base\t") {
            let rest = String(line.dropFirst(5))
            if rest.count >= 32 {
                let cand = String(rest.prefix(32))
                if cand.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) { found = cand }
            }
        }
        return found
    }

    private static func writeBase(savePath: String, hash: String) {
        let target = savePath + ".sync"
        let tmp = target + ".tmp"
        let content = "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud\nbase\t\(hash)\n"
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: tmp), options: .atomic)
            _ = rename(tmp, target)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    private static func isBackupName(_ name: String, side: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2} "# + NSRegularExpression.escapedPattern(for: side) + #"(?: \d+)?$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private static func createBackupDir(savePath: String, side: String) throws -> URL {
        let fm = FileManager.default
        let backupsRoot = URL(fileURLWithPath: savePath + "-backups", isDirectory: true)
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        var candidate = backupsRoot.appendingPathComponent("\(stamp) \(side)", isDirectory: true)
        var k = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = backupsRoot.appendingPathComponent("\(stamp) \(side) \(k)", isDirectory: true)
            k += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        pruneBackups(backupsRoot: backupsRoot, side: side, keeping: candidate.lastPathComponent)
        return candidate
    }

    private static func pruneBackups(backupsRoot: URL, side: String, keeping madeName: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backupsRoot.path) else { return }
        let existing = names.filter { isBackupName($0, side: side) && $0 != madeName }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard existing.count > keepBackups - 1 else { return }
        for old in existing.prefix(existing.count - (keepBackups - 1)) {
            try? fm.removeItem(at: backupsRoot.appendingPathComponent(old))
        }
    }

    private static func coordinatedFetch(from url: URL) throws -> Data? {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: placeholder.path) {
            return nil
        }
        try? fm.startDownloadingUbiquitousItem(at: url)
        var coordError: NSError?
        var result: Result<Data?, Error> = .success(nil)
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            do {
                result = .success(try Data(contentsOf: coordURL))
            } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
                result = .success(nil)
            } catch {
                result = .failure(error)
            }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    private static func coordinatedStore(data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordError: NSError?
        var writeResult: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
            let part = coordURL.path + ".\(getpid()).nosync"
            do {
                try? fm.removeItem(atPath: part)
                try data.write(to: URL(fileURLWithPath: part), options: .atomic)
                if rename(part, coordURL.path) != 0 {
                    let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    try? fm.removeItem(atPath: part)
                    throw err
                }
            } catch {
                writeResult = .failure(error)
            }
        }
        if let coordError { throw coordError }
        try writeResult.get()
    }

    private static func pullRemoteData(_ data: Data, into gameDir: URL, savePath: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let tmp = URL(fileURLWithPath: savePath + ".sync-tmp/in", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tmp)
            try? fm.removeItem(at: URL(fileURLWithPath: savePath + ".sync-tmp", isDirectory: true))
        }
        _ = try unpack(dmsyncData: data, into: tmp)
        var backupDir: URL?
        for folder in archiveFolders {
            let herePath = gameDir.appendingPathComponent(folder).path
            let freshURL = tmp.appendingPathComponent(folder)
            let freshExists = fm.fileExists(atPath: freshURL.path)
            let had = hasSaveEntries(atPath: herePath)
            if had && backupDir == nil { backupDir = try createBackupDir(savePath: savePath, side: "local") }
            if freshExists && fm.fileExists(atPath: herePath) {
                if renamex_np(freshURL.path, herePath, UInt32(RENAME_SWAP)) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if had, let backupDir {
                    try fm.moveItem(at: freshURL, to: backupDir.appendingPathComponent(folder))
                } else {
                    try fm.removeItem(at: freshURL)
                }
            } else if freshExists {
                try fm.moveItem(at: freshURL, to: URL(fileURLWithPath: herePath))
            } else if had, let backupDir {
                try fm.moveItem(atPath: herePath, toPath: backupDir.appendingPathComponent(folder).path)
            }
        }
    }

    @discardableResult
    package static func syncNow(titleID: String, folder: String? = nil, home: String = NSHomeDirectory(),
                                localGameDir: URL? = nil) -> SyncResult {
        let id = titleID.uppercased()
        let baseGameDir = URL(fileURLWithPath: home + "/Library/Application Support/nxnative/" + id)
        let activeGameDir = localGameDir ?? baseGameDir
        let localSavePath = activeGameDir.appendingPathComponent("save").path
        let envURL = baseGameDir.appendingPathComponent("env.txt")
        let curEnv = (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""

        let resolvedFolder: String
        if let folder {
            resolvedFolder = folder
        } else if let envVal = envValue(curEnv), let envFolder = self.folder(for: envVal, home: home) {
            resolvedFolder = envFolder
        } else {
            resolvedFolder = defaultICloudFolder(home: home)
            if envLine(curEnv) == nil {
                try? FileManager.default.createDirectory(at: baseGameDir, withIntermediateDirectories: true)
                try? settingEnv(curEnv, to: "icloud").write(to: envURL, atomically: true, encoding: .utf8)
            }
        }

        let cloudURL = URL(fileURLWithPath: saveFile(folder: resolvedFolder, titleID: id))
        do {
            let localMeta = try scan(from: activeGameDir)
            let base = readBase(savePath: localSavePath)
            let remoteData = try coordinatedFetch(from: cloudURL)
            var remoteMeta: ArchiveMeta?
            if let remoteData {
                let parsed = try inspect(dmsyncData: remoteData)
                guard parsed.title.isEmpty || parsed.title.uppercased() == id else {
                    return .failed("Cloud save belongs to \(parsed.title), not \(id)")
                }
                remoteMeta = parsed
            }
            var both = false
            switch decide(local: localMeta.hash, base: base, remote: remoteMeta?.hash ?? "",
                          localSaved: localMeta.saved, remoteSaved: remoteMeta?.saved ?? 0, bothChanged: &both) {
            case .keep:
                if remoteMeta == nil && localMeta.files == 0 { return .noCloudSave }
                if remoteMeta != nil && localMeta.files > 0 { writeBase(savePath: localSavePath, hash: localMeta.hash) }
                return .upToDate
            case .pull:
                guard let remoteData, let remoteMeta else { return .noCloudSave }
                try pullRemoteData(remoteData, into: activeGameDir, savePath: localSavePath)
                writeBase(savePath: localSavePath, hash: remoteMeta.hash)
                return .downloaded(Date(timeIntervalSince1970: TimeInterval(remoteMeta.saved)))
            case .push:
                if let remoteData, let remoteMeta, remoteMeta.files > 0, !remoteMeta.hash.isEmpty, remoteMeta.hash != base {
                    let backup = try createBackupDir(savePath: localSavePath, side: "cloud")
                    try unpack(dmsyncData: remoteData, into: backup)
                }
                let packed = try pack(from: activeGameDir, titleID: id)
                try coordinatedStore(data: packed, to: cloudURL)
                writeBase(savePath: localSavePath, hash: localMeta.hash)
                return .uploaded(Date(timeIntervalSince1970: TimeInterval(localMeta.saved)))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    package static func syncAllGames(home: String = NSHomeDirectory()) -> [String: SyncResult] {
        let fm = FileManager.default
        var results: [String: SyncResult] = [:]
        let appSupport = home + "/Library/Application Support/nxnative"
        if let list = try? fm.contentsOfDirectory(atPath: appSupport) {
            for item in list {
                let id = item.uppercased()
                guard id.count == 16, UInt64(id, radix: 16) != nil else { continue }
                let envURL = URL(fileURLWithPath: appSupport + "/\(item)/env.txt")
                if let env = try? String(contentsOf: envURL, encoding: .utf8), envValue(env) == "0" { continue }
                results[id] = syncNow(titleID: id, home: home)
            }
        }
        for folder in [altIcloudFolder, icloudFolder] {
            let cloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs/" + folder
            if let titles = try? fm.contentsOfDirectory(atPath: cloudRoot) {
                for item in titles {
                    let id = item.uppercased()
                    guard id.count == 16, UInt64(id, radix: 16) != nil, results[id] == nil else { continue }
                    results[id] = syncNow(titleID: id, home: home)
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
