import Darwin
import Foundation
import ShellUI
import Testing
@testable import ShellHost

private final class MockBridgeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class BridgeMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: Data] = [:]
    var requestedURLs: [String] = []

    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[key]
    }
    func set(_ key: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        files[key] = data
    }
    func record(_ url: String) {
        lock.lock()
        defer { lock.unlock() }
        requestedURLs.append(url)
    }
}

@MainActor @Suite(.serialized) struct CloudSaveSyncServiceTests {
    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockBridgeURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func setMtime(_ url: URL, _ sec: Int) {
        var tv = [timeval(tv_sec: sec, tv_usec: 0), timeval(tv_sec: sec, tv_usec: 0)]
        utimes(url.path, &tv)
    }

    private func shellSettings() -> ShellSettingsStore {
        ShellSettingsStore(defaults: UserDefaults(suiteName: "t-sync-\(UUID().uuidString)")!)
    }

    @Test func normalizeBridgeURLHandlesAllForms() {
        #expect(CloudSaveSyncService.normalizeBridgeURL(nil) == nil)
        #expect(CloudSaveSyncService.normalizeBridgeURL("   \n") == nil)
        #expect(CloudSaveSyncService.normalizeBridgeURL("192.168.1.42") == "http://192.168.1.42:47921/saves")
        #expect(CloudSaveSyncService.normalizeBridgeURL("macbook.local/") == "http://macbook.local:47921/saves")
        #expect(CloudSaveSyncService.normalizeBridgeURL("http://192.168.1.42:47921/saves/") == "http://192.168.1.42:47921/saves")
        #expect(CloudSaveSyncService.normalizeBridgeURL("http://10.0.0.5:8080") == "http://10.0.0.5:8080/saves")
        #expect(CloudSaveSyncService.normalizeBridgeURL("https://saves.example.com/custom/") == "https://saves.example.com/custom")
        #expect(CloudSaveSyncService.normalizeBridgeURL("cloudkit://iCloud.org.example/") == "cloudkit://iCloud.org.example")
        #expect(CloudSaveSyncService.normalizeBridgeURL("http://") == nil)
    }

    @Test func codecRoundTripPreservesGuestXattrMtimeAndRejectsTampering() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sync-codec-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let src = root.appendingPathComponent("src", isDirectory: true)
        let save = src.appendingPathComponent("save", isDirectory: true)
        let sub = save.appendingPathComponent("sub", isDirectory: true)
        let dev = src.appendingPathComponent("save_device", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)

        let f1 = save.appendingPathComponent("slot1.dat")
        let f2 = sub.appendingPathComponent("casefile")
        let f3 = dev.appendingPathComponent("sys.bin")
        let ds = save.appendingPathComponent(".DS_Store")
        try Data("hello".utf8).write(to: f1)
        try Data("guest".utf8).write(to: f2)
        try Data([1, 2, 3]).write(to: f3)
        try Data("junk".utf8).write(to: ds)

        let guest = Data("CaseFile".utf8)
        _ = guest.withUnsafeBytes { raw in
            setxattr(f2.path, CloudSaveSyncService.guestXattrName, raw.baseAddress, guest.count, 0, XATTR_NOFOLLOW)
        }
        setMtime(f1, 1_700_000_000)
        setMtime(f2, 1_700_000_200)
        setMtime(f3, 1_700_000_100)

        let scan1 = try CloudSaveSyncService.scan(from: src)
        #expect(scan1.files == 3)
        #expect(scan1.saved == 1_700_000_200)
        #expect(scan1.hash.count == 32)

        // Mtime changes and .DS_Store do not affect the content hash.
        setMtime(f1, 1_750_000_000)
        let scan2 = try CloudSaveSyncService.scan(from: src)
        #expect(scan1.hash == scan2.hash)

        let packed = try CloudSaveSyncService.pack(from: src, titleID: "010013c00e930000")
        let meta = try CloudSaveSyncService.inspect(dmsyncData: packed)
        #expect(meta.title == "010013C00E930000")
        #expect(meta.files == 3)
        #expect(meta.hash == scan1.hash)

        let dst = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try CloudSaveSyncService.unpack(dmsyncData: packed, into: dst)
        #expect(try Data(contentsOf: dst.appendingPathComponent("save/slot1.dat")) == Data("hello".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("save_device/sys.bin")) == Data([1, 2, 3]))
        var buf = [UInt8](repeating: 0, count: 64)
        let gl = getxattr(dst.appendingPathComponent("save/sub/casefile").path, CloudSaveSyncService.guestXattrName, &buf, buf.count, 0, XATTR_NOFOLLOW)
        #expect(gl == guest.count)
        #expect(Data(buf.prefix(gl)) == guest)

        // Corrupt bytes / truncated archive are refused.
        var tampered = packed
        tampered[packed.count - 10] ^= 0xFF
        #expect(throws: (any Error).self) { _ = try CloudSaveSyncService.inspect(dmsyncData: tampered) }
        #expect(throws: (any Error).self) { _ = try CloudSaveSyncService.inspect(dmsyncData: packed.dropLast(1)) }

        // Empty save directory has empty hash.
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty.appendingPathComponent("save"), withIntermediateDirectories: true)
        let emptyScan = try CloudSaveSyncService.scan(from: empty)
        #expect(emptyScan.files == 0 && emptyScan.hash.isEmpty)
    }

    @Test func folderSyncPushesPullsBackupsAndPrunesToTen() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sync-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        let devA = root.appendingPathComponent("Games/A/\(Fixtures.orbit)", isDirectory: true)
        let devB = root.appendingPathComponent("Games/B/\(Fixtures.orbit)", isDirectory: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        try fm.createDirectory(at: devA.appendingPathComponent("save"), withIntermediateDirectories: true)
        try fm.createDirectory(at: devB, withIntermediateDirectories: true)

        // 1. Empty both -> noCloudSave
        let emptyRes = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: devB, target: .folder(cloud))
        #expect(emptyRes == .noCloudSave)

        // 2. Device A has save -> uploads
        let fileA = devA.appendingPathComponent("save/user.dat")
        try Data("progress-1".utf8).write(to: fileA)
        setMtime(fileA, 1_700_000_010)
        let pushRes = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: devA, target: .folder(cloud))
        guard case .uploaded = pushRes else { Issue.record("Expected upload, got \(pushRes)"); return }

        // 3. Re-sync A -> upToDate
        let sameRes = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: devA, target: .folder(cloud))
        #expect(sameRes == .upToDate)

        // 4. Seed 11 old local backups on B plus an older save -> pull keeps newest 10 local backups
        let backupsB = devB.appendingPathComponent("save-backups", isDirectory: true)
        for i in 0..<11 {
            let d = backupsB.appendingPathComponent(String(format: "2020-01-01 00.00.%02d local", i), isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: devB.appendingPathComponent("save"), withIntermediateDirectories: true)
        let fileB = devB.appendingPathComponent("save/user.dat")
        try Data("stale-local".utf8).write(to: fileB)
        setMtime(fileB, 1_600_000_000)

        let pullRes = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: devB, target: .folder(cloud))
        guard case .downloaded = pullRes else { Issue.record("Expected download, got \(pullRes)"); return }
        #expect(try Data(contentsOf: fileB) == Data("progress-1".utf8))
        let backupNames = try fm.contentsOfDirectory(atPath: backupsB.path).sorted()
        #expect(backupNames.count == 10)
        #expect(!backupNames.contains("2020-01-01 00.00.00 local"))
        #expect(!backupNames.contains("2020-01-01 00.00.01 local"))
    }

    @Test func httpBridgeEnforcesTokenAndRetriesFallback() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        let appFolder = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        let saveFile = appFolder.appendingPathComponent("save/slot.bin")
        try box.write("hero-save", to: saveFile)

        let memory = BridgeMemoryStore()
        MockBridgeURLProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            memory.record(url)
            if url.hasPrefix("http://primary.invalid") {
                throw URLError(.cannotFindHost)
            }
            let auth = req.value(forHTTPHeaderField: "Authorization")
            guard auth == "Bearer tok-123" else {
                let r = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (r, Data("Unauthorized".utf8))
            }
            let tid = Fixtures.orbit.uppercased()
            if req.httpMethod == "GET" {
                if let existing = memory.get(tid) {
                    return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, existing)
                }
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            if req.httpMethod == "PUT" {
                var body = Data()
                if let stream = req.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buf = [UInt8](repeating: 0, count: 65_536)
                    while stream.hasBytesAvailable {
                        let n = stream.read(&buf, maxLength: buf.count)
                        if n <= 0 { break }
                        body.append(contentsOf: buf.prefix(n))
                    }
                } else if let d = req.httpBody {
                    body = d
                }
                memory.set(tid, data: body)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("OK".utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 405, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockBridgeURLProtocol.handler = nil }

        let session = makeSession()
        let target = CloudSaveSyncService.RemoteTarget.http(
            primary: "http://primary.invalid:47921/saves",
            fallback: "http://127.0.0.1:47921/saves"
        )

        // Wrong token returns failure and does not store.
        let bad = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: appFolder, target: target, token: "wrong", session: session)
        if case .failed(let msg) = bad {
            #expect(msg == hostText("Access key rejected"))
        } else {
            Issue.record("Expected auth failure, got \(bad)")
        }
        #expect(memory.get(Fixtures.orbit) == nil)

        // Correct token falls back cleanly and uploads.
        let ok = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: appFolder, target: target, token: "tok-123", session: session)
        guard case .uploaded = ok else { Issue.record("Expected upload, got \(ok)"); return }
        #expect(memory.get(Fixtures.orbit) != nil)
        #expect(memory.requestedURLs.contains { $0.hasPrefix("http://primary.invalid:47921") })
        #expect(memory.requestedURLs.contains { $0.hasPrefix("http://127.0.0.1:47921/saves/\(Fixtures.orbit)/save.dmsync") })
    }

    @Test func hostModelSyncsManuallyAppliesRuntimeBridgeAndRespectsOptOut() async throws {
        let box = try Sandbox()
        try box.giveAppData(Fixtures.orbit)
        try box.write("save-A", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("save/a.bin"))

        let memory = BridgeMemoryStore()
        MockBridgeURLProtocol.handler = { req in
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer runtime-tok" else {
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
            }
            let tid = req.url?.pathComponents.dropLast().last?.uppercased() ?? ""
            if req.httpMethod == "GET" {
                if let d = memory.get(tid) {
                    return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, d)
                }
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            var body = Data()
            if let stream = req.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buf = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    body.append(contentsOf: buf.prefix(n))
                }
            } else if let d = req.httpBody {
                body = d
            }
            memory.set(tid, data: body)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockBridgeURLProtocol.handler = nil }

        let shell = shellSettings()
        let launcher = RecordingLauncher()
        let config = ShellHostConfig(
            gamesRoot: box.games,
            appDataRoot: box.appData,
            environment: HostEnvironment(chain: "b-3f9a2c"),
            saveBridgeURL: "http://old.example:47921/saves",
            saveBridgeToken: "old-tok",
            defaults: { box.defaults($0) }
        )
        let model = ShellHostModel(
            config: config,
            launcher: launcher,
            shellSettings: shell,
            urlSession: makeSession(),
            discoverBridge: { "http://192.168.1.99:47921/saves" }
        )

        // Discover Mac over Wi-Fi updates runtime bridge URL.
        await model.discoverSaveBridgeNow()
        #expect(shell.saveBridgeURL == "http://192.168.1.99:47921/saves")
        #expect(model.shellCloudStatus == hostText("Found Mac on Wi-Fi"))

        // User edits server address & access key with stray whitespace (trimmed & bare IP normalized).
        model.saveBridgeChanged(url: " 127.0.0.1 ", token: " runtime-tok \n")
        #expect(shell.saveBridgeURL == "http://127.0.0.1:47921/saves")
        #expect(shell.saveBridgeToken == "runtime-tok")

        let orbitDetail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbitDetail.cloudSaves == hostText("Save server"))
        #expect(orbitDetail.cloudFromShell)

        // Play passes runtime bridge + token into EngineLaunchPlan.
        await model.playNow(Fixtures.orbit)
        let game = try #require(launcher.launched.last)
        #expect(game.saveSyncTarget == "http://127.0.0.1:47921/saves")
        #expect(game.saveSyncToken == "runtime-tok")
        let plan = EngineLaunchPlan.make(game: game, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_SAVE_SYNC"] == "http://127.0.0.1:47921/saves")
        #expect(plan.environment["DM_SAVE_SYNC_TOKEN"] == "runtime-tok")

        // Per-game manual sync uploads to runtime bridge.
        await model.syncCloudSavesNow(Fixtures.orbit)
        #expect(memory.get(Fixtures.orbit) != nil)
        let syncedOrbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(syncedOrbit.cloudSyncStatus == hostText("Save uploaded"))

        // Syncing again is up to date; opt-out skips game in syncAllCloudSavesNow.
        model.actions.onDisableCloudSaves("0100000000080000")
        await model.syncAllCloudSavesNow()
        #expect(model.shellCloudStatus == hostText("All saves up to date"))
        #expect(memory.get("0100000000080000") == nil)
    }

    @Test func corruptOrMismatchedRemoteArchiveFailsWithoutOverwriting() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sync-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        let dev = root.appendingPathComponent("Games/\(Fixtures.orbit)", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try fm.createDirectory(at: cloud.appendingPathComponent(Fixtures.orbit), withIntermediateDirectories: true)
        try fm.createDirectory(at: dev.appendingPathComponent("save"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: dev.appendingPathComponent("save/user.dat"))
        try Data("other".utf8).write(to: other.appendingPathComponent("save/user.dat"))

        let cloudFile = cloud.appendingPathComponent("\(Fixtures.orbit)/save.dmsync")
        let corruptData = Data("corrupt-archive-bytes".utf8)
        try corruptData.write(to: cloudFile)

        let res1 = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: dev, target: .folder(cloud))
        guard case .failed = res1 else {
            Issue.record("Expected failure on corrupt cloud archive, got \(res1)")
            return
        }
        #expect(try Data(contentsOf: cloudFile) == corruptData)

        let wrongTitleData = try CloudSaveSyncService.pack(from: other, titleID: "010013C00E930000")
        try wrongTitleData.write(to: cloudFile)

        let res2 = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: dev, target: .folder(cloud))
        guard case .failed = res2 else {
            Issue.record("Expected failure on wrong-title cloud archive, got \(res2)")
            return
        }
        #expect(try Data(contentsOf: cloudFile) == wrongTitleData)
    }

    @Test func profileURLsAndEndpointFetchingBehaveCleanly() async throws {
        #expect(CloudSaveSyncService.profileBaseURL("http://192.168.1.10:47921/saves", profileID: "default") == "http://192.168.1.10:47921/saves")
        #expect(CloudSaveSyncService.profileBaseURL("http://192.168.1.10:47921/saves", profileID: "maite") == "http://192.168.1.10:47921/saves/profiles/maite")
        #expect(CloudSaveSyncService.profileBaseURL("http://192.168.1.10:47921/saves/profiles/old", profileID: "maite") == "http://192.168.1.10:47921/saves/profiles/maite")
        #expect(CloudSaveSyncService.profileBaseURL("cloudkit://iCloud.org.example", profileID: "default") == "cloudkit://iCloud.org.example")
        #expect(CloudSaveSyncService.profileBaseURL("cloudkit://iCloud.org.example/profiles/old", profileID: "maite") == "cloudkit://iCloud.org.example/profiles/maite")
        #expect(CloudSaveSyncService.profilesEndpointURL(base: "http://192.168.1.10:47921/saves/profiles/maite")?.absoluteString == "http://192.168.1.10:47921/saves/profiles.json")

        nonisolated(unsafe) var mode = "ok"
        MockBridgeURLProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.hasPrefix("http://primary.invalid") { throw URLError(.cannotFindHost) }
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer tok-prof" else {
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
            }
            switch mode {
            case "ok":
                let json = Data(#"[{"id":"default","name":"Luis Felipe"},{"id":"maite","name":"Maite"}]"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            case "404":
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        defer { MockBridgeURLProtocol.handler = nil }

        let session = makeSession()
        let fetched = try await CloudSaveSyncService.fetchSaveProfiles(
            base: "http://primary.invalid:47921/saves", fallback: "http://127.0.0.1:47921/saves", token: "tok-prof", session: session)
        #expect(fetched == [
            CloudSaveSyncService.RemoteSaveProfile(id: "default", name: "Luis Felipe"),
            CloudSaveSyncService.RemoteSaveProfile(id: "maite", name: "Maite"),
        ])

        mode = "404"
        let missing = try await CloudSaveSyncService.fetchSaveProfiles(base: "http://127.0.0.1:47921/saves", token: "tok-prof", session: session)
        #expect(missing == nil)

        await #expect(throws: (any Error).self) {
            _ = try await CloudSaveSyncService.fetchSaveProfiles(base: "http://127.0.0.1:47921/saves", token: "bad", session: session)
        }
    }

    @Test func hostModelIsolatesPerProfileSavesFoldersAndBridgeURLs() async throws {
        let box = try Sandbox()
        try box.giveAppData(Fixtures.orbit)
        let orbitFolder = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try box.write("luis-save", to: orbitFolder.appendingPathComponent("save/slot.bin"))
        try box.write("maite-save", to: orbitFolder.appendingPathComponent("profiles/maite/save/slot.bin"))

        let cloudFolder = box.root.appendingPathComponent("iCloudRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)

        let memory = BridgeMemoryStore()
        MockBridgeURLProtocol.handler = { req in
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer tok-multi" else {
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
            }
            let path = req.url?.path ?? ""
            if req.httpMethod == "GET" && path.hasSuffix("/profiles.json") {
                let json = Data(#"[{"id":"default","name":"Luis Felipe"},{"id":"maite","name":"Maite"}]"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }
            if req.httpMethod == "GET" {
                if let d = memory.get(path) {
                    return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, d)
                }
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            if req.httpMethod == "PUT" {
                var body = Data()
                if let stream = req.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buf = [UInt8](repeating: 0, count: 65_536)
                    while stream.hasBytesAvailable {
                        let n = stream.read(&buf, maxLength: buf.count)
                        if n <= 0 { break }
                        body.append(contentsOf: buf.prefix(n))
                    }
                } else if let d = req.httpBody {
                    body = d
                }
                memory.set(path, data: body)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 405, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockBridgeURLProtocol.handler = nil }

        let shell = shellSettings()
        let launcher = RecordingLauncher()
        let config = ShellHostConfig(
            gamesRoot: box.games,
            appDataRoot: box.appData,
            environment: HostEnvironment(chain: "b-3f9a2c"),
            saveBridgeURL: "http://127.0.0.1:47921/saves",
            saveBridgeToken: "tok-multi",
            defaults: { box.defaults($0) }
        )
        let model = ShellHostModel(config: config, launcher: launcher, shellSettings: shell, urlSession: makeSession())
        await model.refreshSaveProfilesNow(silent: false)
        #expect(model.profilesStatus == hostText("Profiles updated from Mac"))
        #expect(model.saveProfiles.map(\.name) == ["Luis Felipe", "Maite"])
        #expect(model.activeSaveProfile.id == "default")
        #expect(model.details.first { $0.id == Fixtures.orbit }?.activeProfileName == "Luis Felipe")

        // Sync + launch as default ("Luis Felipe") uses /saves/<TID>/save.dmsync and <game>/
        await model.syncCloudSavesNow(Fixtures.orbit)
        #expect(memory.get("/saves/\(Fixtures.orbit)/save.dmsync") != nil)
        #expect(memory.get("/saves/profiles/maite/\(Fixtures.orbit)/save.dmsync") == nil)
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.last?.saveContainerURL?.path == orbitFolder.path)
        #expect(launcher.launched.last?.saveSyncTarget == "http://127.0.0.1:47921/saves")

        // Switch to Maite -> uses /saves/profiles/maite/<TID>/save.dmsync and <game>/profiles/maite
        model.selectSaveProfile("maite")
        #expect(model.activeSaveProfile.name == "Maite")
        #expect(model.details.first { $0.id == Fixtures.orbit }?.activeProfileName == "Maite")
        await model.syncCloudSavesNow(Fixtures.orbit)
        let luisArchive = try #require(memory.get("/saves/\(Fixtures.orbit)/save.dmsync"))
        let maiteArchive = try #require(memory.get("/saves/profiles/maite/\(Fixtures.orbit)/save.dmsync"))
        #expect(luisArchive != maiteArchive)
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.last?.saveContainerURL?.path == orbitFolder.appendingPathComponent("profiles/maite").path)
        #expect(launcher.launched.last?.saveSyncTarget == "http://127.0.0.1:47921/saves/profiles/maite")

        // Folder sync also isolates default vs custom profile cleanly.
        let folderSyncDefault = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: orbitFolder, target: .folder(cloudFolder), profileID: "default")
        let folderSyncMaite = await CloudSaveSyncService.syncGame(titleID: Fixtures.orbit, gameAppFolder: orbitFolder.appendingPathComponent("profiles/maite"), target: .folder(cloudFolder), profileID: "maite")
        guard case .uploaded = folderSyncDefault, case .uploaded = folderSyncMaite else {
            Issue.record("Expected both profile folder syncs to upload"); return
        }
        #expect(FileManager.default.fileExists(atPath: cloudFolder.appendingPathComponent("\(Fixtures.orbit)/save.dmsync").path))
        #expect(FileManager.default.fileExists(atPath: cloudFolder.appendingPathComponent("profiles/maite/\(Fixtures.orbit)/save.dmsync").path))
    }
}
