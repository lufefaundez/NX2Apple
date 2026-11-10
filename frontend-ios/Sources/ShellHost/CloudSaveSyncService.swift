import CommonCrypto
import Darwin
import Foundation
import Network
#if canImport(CloudKit)
import CloudKit
#endif

/// Pure Swift `.dmsync` save bundler, 3-way merge, LAN Save Bridge HTTP + Bonjour client,
/// CloudKit private-DB transport, and coordinated iCloud/folder sync for iOS and tvOS.
public enum CloudSaveSyncService {
    public static let defaultPort: UInt16 = 47921
    public static let bonjourType = "_nx2apple-saves._tcp"
    public static let guestXattrName = "org.d2rmobile.guest-name"
    private static let archiveFolders = ["save", "save_device"]
    private static let magic = Data("DMSYNC1\n".utf8)
    private static let endMarker = Data("DMSYNCE\n".utf8)
    private static let keepBackups = 10

    public enum SyncOutcome: Equatable, Sendable {
        case upToDate
        case downloaded(Date)
        case uploaded(Date)
        case noCloudSave
        case failed(String)
    }

    public enum RemoteTarget: Equatable, Sendable {
        case folder(URL)
        case cloudKit(String)
        case http(primary: String, fallback: String?)
    }

    public struct ArchiveMeta: Equatable, Sendable {
        public var hash: String
        public var saved: Int64
        public var title: String
        public var device: String
        public var files: Int

        public init(hash: String = "", saved: Int64 = 0, title: String = "", device: String = "", files: Int = 0) {
            self.hash = hash
            self.saved = saved
            self.title = title
            self.device = device
            self.files = files
        }
    }

    public enum MergeDecision: Equatable, Sendable {
        case keep, pull, push
    }

    // MARK: - URL normalization & Bonjour LAN discovery

    /// Normalizes a user-supplied Save Bridge server address.
    /// - Preserves `cloudkit://...` and explicit custom paths.
    /// - Prepends `http://` when no scheme is provided.
    /// - For `http://` with an empty or `/` path and no explicit port, defaults port to `47921` and path to `/saves`.
    /// - Strips trailing slashes from non-root paths.
    public static func normalizeBridgeURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("cloudkit://") {
            var ck = trimmed
            while ck.count > "cloudkit://".count && ck.hasSuffix("/") { ck.removeLast() }
            return ck == "cloudkit://" ? nil : ck
        }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var comps = URLComponents(string: withScheme),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        comps.scheme = scheme
        if comps.path.isEmpty || comps.path == "/" {
            if scheme == "http" && comps.port == nil {
                comps.port = Int(defaultPort)
            }
            comps.path = "/saves"
        } else {
            while comps.path.count > 1 && comps.path.hasSuffix("/") {
                comps.path.removeLast()
            }
        }
        return comps.string
    }

    private final class DiscoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var browser: NWBrowser?
        private var connections: [NWConnection] = []
        private var timeoutItem: DispatchWorkItem?
        private var continuation: CheckedContinuation<String?, Never>?

        func install(browser: NWBrowser, continuation: CheckedContinuation<String?, Never>, timeoutItem: DispatchWorkItem) {
            lock.lock()
            self.browser = browser
            self.continuation = continuation
            self.timeoutItem = timeoutItem
            lock.unlock()
        }

        func addConnection(_ connection: NWConnection) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            connections.append(connection)
            return true
        }

        func finish(with url: String?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let cont = continuation
            continuation = nil
            let b = browser
            browser = nil
            let conns = connections
            connections.removeAll()
            let timer = timeoutItem
            timeoutItem = nil
            lock.unlock()

            timer?.cancel()
            b?.cancel()
            for c in conns { c.cancel() }
            cont?.resume(returning: url)
        }
    }

    /// Searches the local Wi-Fi network for NX2Apple's Save Bridge Bonjour service (`_nx2apple-saves._tcp`)
    /// and resolves its IPv4 address + port into `"http://<ip>:<port>/saves"`.
    public static func discoverSaveBridge(timeout: Duration = .seconds(3)) async -> String? {
        let state = DiscoveryState()
        let queue = DispatchQueue(label: "dev.nx2apple.shell.save-bridge-discovery", qos: .userInitiated)
        let nanos = max(100_000_000, Int64(timeout.components.seconds) * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let params = NWParameters.tcp
                let browser = NWBrowser(for: .bonjour(type: bonjourType, domain: "local."), using: params)
                let timer = DispatchWorkItem {
                    state.finish(with: nil)
                }
                state.install(browser: browser, continuation: continuation, timeoutItem: timer)
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(nanos, Int64(Int.max)))), execute: timer)

                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        resolveEndpoint(result.endpoint, queue: queue, state: state)
                    }
                }
                browser.stateUpdateHandler = { browserState in
                    if case .failed = browserState {
                        state.finish(with: nil)
                    }
                }
                browser.start(queue: queue)
            }
        } onCancel: {
            state.finish(with: nil)
        }
    }

    private static func resolveEndpoint(_ endpoint: NWEndpoint, queue: DispatchQueue, state: DiscoveryState) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        guard state.addConnection(connection) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { connState in
            switch connState {
            case .ready:
                if let resolved = extractBridgeURL(from: connection.currentPath?.remoteEndpoint) {
                    state.finish(with: resolved)
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func extractBridgeURL(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let portNum = port.rawValue
        guard portNum > 0 else { return nil }
        switch host {
        case .ipv4(let addr):
            let b = addr.rawValue
            guard b.count == 4 else { return nil }
            let ip = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            return "http://\(ip):\(portNum)/saves"
        case .name(let hostname, _) where !hostname.isEmpty:
            return "http://\(hostname):\(portNum)/saves"
        case .name, .ipv6:
            return nil
        @unknown default:
            return nil
        }
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

    private struct SHA256Hasher {
        private var ctx = CC_SHA256_CTX()
        init() { CC_SHA256_Init(&ctx) }
        mutating func update(_ data: Data) {
            guard !data.isEmpty else { return }
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    CC_SHA256_Update(&ctx, base, CC_LONG(raw.count))
                }
            }
        }
        mutating func shortHexDigest() -> String {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256_Final(&digest, &ctx)
            return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func deviceModel() -> String {
        var size = 0
        #if os(macOS)
        let name = "hw.model"
        let fallback = "Mac"
        #else
        let name = "hw.machine"
        let fallback = "Apple"
        #endif
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return fallback }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return fallback }
        let model = buf.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
        return model.isEmpty ? fallback : model
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

    public static func scan(from dir: URL) throws -> ArchiveMeta {
        var entries: [WalkEntry] = []
        for folder in archiveFolders {
            let folderPath = dir.appendingPathComponent(folder).path
            if hasSaveEntries(atPath: folderPath) {
                try walkSaveDirectory(absPath: folderPath, relPath: folder, into: &entries)
            }
        }
        var sha = SHA256Hasher()
        var files = 0
        var saved: Int64 = 0
        for e in entries {
            let pathData = Data(e.relativePath.utf8)
            guard pathData.count <= Int(UInt16.max), e.guestName.count <= Int(UInt16.max) else {
                throw NSError(domain: "DMSync", code: 6, userInfo: [NSLocalizedDescriptionKey: "Path exceeds entry limit"])
            }
            let h16 = entryHeader16(type: e.isDirectory ? 1 : 2, pathLen: UInt16(pathData.count),
                                    guestLen: UInt16(e.guestName.count), size: e.isDirectory ? 0 : UInt64(e.data.count))
            sha.update(h16)
            sha.update(pathData)
            sha.update(e.guestName)
            if !e.isDirectory {
                sha.update(e.data)
                files += 1
                if e.mtime > saved { saved = e.mtime }
            }
        }
        let hash = files > 0 ? sha.shortHexDigest() : ""
        return ArchiveMeta(hash: hash, saved: saved, title: "", device: "", files: files)
    }

    public static func pack(from dir: URL, titleID: String) throws -> Data {
        var entries: [WalkEntry] = []
        for folder in archiveFolders {
            let folderPath = dir.appendingPathComponent(folder).path
            if hasSaveEntries(atPath: folderPath) {
                try walkSaveDirectory(absPath: folderPath, relPath: folder, into: &entries)
            }
        }
        var sha = SHA256Hasher()
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
            sha.update(h16)
            sha.update(pathData)
            sha.update(e.guestName)
            body.append(h16)
            appendLE(&body, e.mtime)
            body.append(pathData)
            body.append(e.guestName)
            if !e.isDirectory {
                sha.update(e.data)
                body.append(e.data)
                files += 1
                if e.mtime > saved { saved = e.mtime }
            }
        }
        let hash = files > 0 ? sha.shortHexDigest() : ""
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
        var sha = SHA256Hasher()
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

            sha.update(header16)
            sha.update(pathData)
            sha.update(guestData)
            if entryType == 2 {
                sha.update(data[payloadRange])
                regularFiles += 1
            }
            parsed.append(ParsedEntry(relativePath: path, isDirectory: entryType == 1, guestName: guestData, mtime: mt, payloadRange: payloadRange))
        }

        guard offset == limitOffset, data[offset..<offset + 8] == endMarker else {
            throw NSError(domain: "DMSync", code: 7, userInfo: [NSLocalizedDescriptionKey: "Truncated or invalid end marker"])
        }
        let hash = regularFiles > 0 ? sha.shortHexDigest() : ""
        guard hash == wantHash else {
            throw NSError(domain: "DMSync", code: 8, userInfo: [NSLocalizedDescriptionKey: "Save archive checksum mismatch"])
        }
        return (ArchiveMeta(hash: hash, saved: saved, title: title, device: device, files: regularFiles), parsed)
    }

    public static func inspect(dmsyncData data: Data) throws -> ArchiveMeta {
        try parseAndVerify(dmsyncData: data).meta
    }

    @discardableResult
    public static func unpack(dmsyncData data: Data, into dir: URL) throws -> ArchiveMeta {
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

    // MARK: - 3-way merge, base stamp, backups

    public static func decide(local: String, base: String, remote: String, localSaved: Int64, remoteSaved: Int64, bothChanged: inout Bool) -> MergeDecision {
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

    // MARK: - Transports (folder, HTTP Save Bridge, CloudKit)

    private static func folderSaveURL(folder: URL, titleID: String) -> URL {
        let id = titleID.uppercased()
        if folder.lastPathComponent.uppercased() == id {
            return folder.appendingPathComponent("save.dmsync")
        }
        return folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("save.dmsync")
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

    private static func endpointURL(base: String, titleID: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.count > 1 && b.hasSuffix("/") { b.removeLast() }
        return URL(string: "\(b)/\(titleID.uppercased())/save.dmsync")
    }

    private static func httpFetch(base: String, fallback: String?, titleID: String, token: String?, session: URLSession) async throws -> (data: Data?, preferredBase: String) {
        let timeout: TimeInterval = (fallback != nil && fallback != base) ? 4.0 : 8.0
        do {
            let data = try await httpFetchOnce(base: base, titleID: titleID, token: token, timeout: timeout, session: session)
            return (data, base)
        } catch let urlErr as URLError {
            if let fallback, fallback != base, !fallback.isEmpty {
                let data = try await httpFetchOnce(base: fallback, titleID: titleID, token: token, timeout: 4.0, session: session)
                return (data, fallback)
            }
            throw NSError(domain: "DMSync", code: urlErr.errorCode, userInfo: [NSLocalizedDescriptionKey: hostText("Save server unreachable")])
        }
    }

    private static func httpFetchOnce(base: String, titleID: String, token: String?, timeout: TimeInterval, session: URLSession) async throws -> Data? {
        guard let url = endpointURL(base: base, titleID: titleID) else {
            throw NSError(domain: "DMSync", code: 10, userInfo: [NSLocalizedDescriptionKey: hostText("Save server unreachable")])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DMSync", code: 11, userInfo: [NSLocalizedDescriptionKey: hostText("Save server unreachable")])
        }
        switch http.statusCode {
        case 200:
            return data
        case 404:
            return nil
        case 401, 403:
            throw NSError(domain: "DMSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: hostText("Access key rejected")])
        default:
            throw NSError(domain: "DMSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: hostText("Save server error (\(String(http.statusCode)))")])
        }
    }

    private static func httpStore(data: Data, base: String, fallback: String?, titleID: String, token: String?, session: URLSession) async throws {
        let timeout: TimeInterval = (fallback != nil && fallback != base) ? 5.0 : 10.0
        do {
            try await httpStoreOnce(data: data, base: base, titleID: titleID, token: token, timeout: timeout, session: session)
        } catch let urlErr as URLError {
            if let fallback, fallback != base, !fallback.isEmpty {
                try await httpStoreOnce(data: data, base: fallback, titleID: titleID, token: token, timeout: 5.0, session: session)
                return
            }
            throw NSError(domain: "DMSync", code: urlErr.errorCode, userInfo: [NSLocalizedDescriptionKey: hostText("Save server unreachable")])
        }
    }

    private static func httpStoreOnce(data: Data, base: String, titleID: String, token: String?, timeout: TimeInterval, session: URLSession) async throws {
        guard let url = endpointURL(base: base, titleID: titleID) else {
            throw NSError(domain: "DMSync", code: 10, userInfo: [NSLocalizedDescriptionKey: hostText("Save server unreachable")])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DMSync", code: 11, userInfo: [NSLocalizedDescriptionKey: hostText("Save server unreachable")])
        }
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 401, 403:
            throw NSError(domain: "DMSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: hostText("Access key rejected")])
        default:
            throw NSError(domain: "DMSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: hostText("Save server error (\(String(http.statusCode)))")])
        }
    }

    private static func parseCloudKitContainer(_ target: String) -> String? {
        guard target.hasPrefix("cloudkit://") else { return nil }
        let rest = String(target.dropFirst("cloudkit://".count))
        let container = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return container.isEmpty ? nil : container
    }

    private static func cloudKitFetch(containerID: String, titleID: String) async throws -> Data? {
        #if canImport(CloudKit)
        let db = CKContainer(identifier: containerID).privateCloudDatabase
        let rid = CKRecord.ID(recordName: "save-\(titleID.uppercased())")
        do {
            let record = try await db.record(for: rid)
            guard let asset = record["bundle"] as? CKAsset, let fileURL = asset.fileURL else {
                return nil
            }
            return try Data(contentsOf: fileURL)
        } catch let err as CKError where err.code == .unknownItem {
            return nil
        }
        #else
        throw NSError(domain: "DMSync", code: 12, userInfo: [NSLocalizedDescriptionKey: "CloudKit unavailable"])
        #endif
    }

    private static func cloudKitStore(data: Data, containerID: String, titleID: String) async throws {
        #if canImport(CloudKit)
        let id = titleID.uppercased()
        let db = CKContainer(identifier: containerID).privateCloudDatabase
        let rid = CKRecord.ID(recordName: "save-\(id)")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dmsync-ck-\(id)-\(UUID().uuidString).dmsync")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let record = CKRecord(recordType: "NXSave", recordID: rid)
        record["bundle"] = CKAsset(fileURL: tmp)
        record["title"] = id as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        #else
        throw NSError(domain: "DMSync", code: 12, userInfo: [NSLocalizedDescriptionKey: "CloudKit unavailable"])
        #endif
    }

    // MARK: - High-level per-game sync & UI status mapping

    public static func statusMessage(for outcome: SyncOutcome) -> String {
        switch outcome {
        case .upToDate: hostText("Saves up to date")
        case .downloaded: hostText("Save downloaded")
        case .uploaded: hostText("Save uploaded")
        case .noCloudSave: hostText("No save here or in the cloud yet")
        case .failed(let reason): hostText("Save sync failed: \(reason)")
        }
    }

    public static func syncGame(titleID: String, gameAppFolder: URL, target: RemoteTarget, token: String? = nil,
                                session: URLSession = .shared) async -> SyncOutcome {
        let id = titleID.uppercased()
        let localSavePath = gameAppFolder.appendingPathComponent("save").path
        do {
            let localMeta = try await Task.detached(priority: .userInitiated) {
                try scan(from: gameAppFolder)
            }.value
            let base = readBase(savePath: localSavePath)

            let remoteData: Data?
            var activeHTTPBase: String?
            var fallbackHTTPBase: String?
            switch target {
            case .folder(let folderURL):
                let fileURL = folderSaveURL(folder: folderURL, titleID: id)
                remoteData = try await Task.detached(priority: .userInitiated) {
                    try coordinatedFetch(from: fileURL)
                }.value
            case .cloudKit(let container):
                remoteData = try await cloudKitFetch(containerID: container, titleID: id)
            case .http(let primary, let fallback):
                let fetched = try await httpFetch(base: primary, fallback: fallback, titleID: id, token: token, session: session)
                remoteData = fetched.data
                activeHTTPBase = fetched.preferredBase
                fallbackHTTPBase = (fetched.preferredBase == primary) ? fallback : primary
            }

            var remoteMeta: ArchiveMeta?
            if let remoteData {
                let parsed = try inspect(dmsyncData: remoteData)
                guard parsed.title.isEmpty || parsed.title.uppercased() == id else {
                    throw NSError(domain: "DMSync", code: 9, userInfo: [
                        NSLocalizedDescriptionKey: "Cloud save belongs to \(parsed.title), not \(id)"
                    ])
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
                try await Task.detached(priority: .userInitiated) {
                    try pullRemoteData(remoteData, into: gameAppFolder, savePath: localSavePath)
                }.value
                writeBase(savePath: localSavePath, hash: remoteMeta.hash)
                return .downloaded(Date(timeIntervalSince1970: TimeInterval(remoteMeta.saved)))

            case .push:
                if let remoteData, let remoteMeta, remoteMeta.files > 0, !remoteMeta.hash.isEmpty, remoteMeta.hash != base {
                    let backup = try createBackupDir(savePath: localSavePath, side: "cloud")
                    try await Task.detached(priority: .userInitiated) {
                        _ = try unpack(dmsyncData: remoteData, into: backup)
                    }.value
                }
                let packed = try await Task.detached(priority: .userInitiated) {
                    try pack(from: gameAppFolder, titleID: id)
                }.value
                switch target {
                case .folder(let folderURL):
                    let fileURL = folderSaveURL(folder: folderURL, titleID: id)
                    try await Task.detached(priority: .userInitiated) {
                        try coordinatedStore(data: packed, to: fileURL)
                    }.value
                case .cloudKit(let container):
                    try await cloudKitStore(data: packed, containerID: container, titleID: id)
                case .http(let primary, _):
                    try await httpStore(data: packed, base: activeHTTPBase ?? primary, fallback: fallbackHTTPBase, titleID: id, token: token, session: session)
                }
                writeBase(savePath: localSavePath, hash: localMeta.hash)
                return .uploaded(Date(timeIntervalSince1970: TimeInterval(localMeta.saved)))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func makeRemoteTarget(target: String?, fallback: String?) -> RemoteTarget? {
        guard let target = normalizeBridgeURL(target) else { return nil }
        if target.hasPrefix("cloudkit://"), let container = parseCloudKitContainer(target) {
            return .cloudKit(container)
        }
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            let normFallback = normalizeBridgeURL(fallback)
            let validFallback = (normFallback?.hasPrefix("http://") == true || normFallback?.hasPrefix("https://") == true) ? normFallback : nil
            return .http(primary: target, fallback: validFallback == target ? nil : validFallback)
        }
        return nil
    }
}
