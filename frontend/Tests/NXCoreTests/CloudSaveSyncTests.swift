import CryptoKit
import Darwin
import XCTest
@testable import NXCore

/// #499: the cloud saves folder a Mac game uses, read as dm/mac/launcher.c reads it, and the sync state of its last session's log.
final class CloudSaveSyncTests: XCTestCase {
    private let home = "/Users/jo"
    private let drive = "/Users/jo/Library/Mobile Documents/com~apple~CloudDocs"
    private let id = "0100535012974000"

    // ---- env.txt files as older versions and players wrote them ----

    /// What CloudSavesMigration wrote in v0.9 for a game on the old keyword: its comment, then the path.
    func testTheMigrationsPinnedPathCounts() {
        let text = CloudSavesMigration.comment + "\nDM_SAVE_SYNC=\(drive)/NX2Apple Saves\nDM_FPS_TARGET=60\n"
        let s = CloudSaveSync.resolve(playerEnv: text, appEnv: nil, preference: "/Elsewhere", home: home)
        XCTAssertEqual(s, .init(source: .playerEnv, value: "\(drive)/NX2Apple Saves", folder: "\(drive)/NX2Apple Saves"))
    }

    /// The keyword a player wrote by hand, with Windows line ends (#490 had one like it).
    func testTheIcloudKeywordIsNxnativeSaves() {
        let s = CloudSaveSync.resolve(playerEnv: "DM_SAVE_SYNC=icloud\r\n", appEnv: nil, preference: nil, home: home)
        XCTAssertEqual(s.folder, "\(drive)/nxnative Saves")
        XCTAssertEqual(s.value, "icloud")
    }

    func testCommentsSpacesAndTheFirstLineRule() {
        XCTAssertNil(CloudSaveSync.envValue("# DM_SAVE_SYNC=/old\n  #DM_SAVE_SYNC=/older\n"))
        XCTAssertEqual(CloudSaveSync.envValue("  DM_SAVE_SYNC =/a folder/  \t\nDM_SAVE_SYNC=/second\n"), "/a folder/")
        XCTAssertEqual(CloudSaveSync.envValue("DM_SAVE_SYNC= /x\n"), " /x", "launcher.c keeps what follows the = as it is")
        XCTAssertEqual(CloudSaveSync.folder(for: "/a folder/"), "/a folder")
        XCTAssertNil(CloudSaveSync.envValue("DM_SAVE_SYNCX=/no\n=nothing\n"))
    }

    func testOffWinsOverLaterPlaces() {
        let s = CloudSaveSync.resolve(playerEnv: "DM_SAVE_SYNC=0\n", appEnv: "DM_SAVE_SYNC=icloud\n", preference: "/P", home: home)
        XCTAssertEqual(s.source, .playerEnv)
        XCTAssertFalse(s.isOn)
    }

    func testTheOrderIsPlayerEnvThenAppEnvThenThePreference() {
        XCTAssertEqual(CloudSaveSync.resolve(playerEnv: "DM_FPS_TARGET=30\n", appEnv: "DM_SAVE_SYNC=/App\n", preference: "/P").source, .appEnv)
        XCTAssertEqual(CloudSaveSync.resolve(playerEnv: nil, appEnv: nil, preference: "/P"), .init(source: .preference, value: "/P", folder: "/P"))
        XCTAssertEqual(CloudSaveSync.resolve(playerEnv: nil, appEnv: nil, preference: ""), .init(source: .none, value: nil, folder: nil))
    }

    func testSettingTheLineKeepsEverythingElse() {
        let old = CloudSavesMigration.comment + "\r\nDM_SAVE_SYNC=icloud\r\nDM_FPS_TARGET=60\r\n"
        XCTAssertEqual(CloudSaveSync.settingEnv(old, to: "/New"), CloudSavesMigration.comment + "\r\nDM_SAVE_SYNC=/New\r\nDM_FPS_TARGET=60\r\n")
        XCTAssertEqual(CloudSaveSync.settingEnv("DM_FPS_TARGET=60", to: "0"), "DM_FPS_TARGET=60\nDM_SAVE_SYNC=0\n")
        XCTAssertEqual(CloudSaveSync.settingEnv(nil, to: "/New"), "DM_SAVE_SYNC=/New\n")
    }

    func testTheSaveFileFollowsCloudFile() {
        XCTAssertEqual(CloudSaveSync.saveFile(folder: "/C/Saves", titleID: id.lowercased()), "/C/Saves/\(id)/save.dmsync")
        XCTAssertEqual(CloudSaveSync.saveFile(folder: "/C/Saves/\(id.lowercased())", titleID: id), "/C/Saves/\(id.lowercased())/save.dmsync",
                       "the game's own folder is not given a second title ID")
    }

    func testTheFolderCheckSeesAWrongFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(CloudSaveSync.check(folder: root.path, titleID: id), .missing)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        XCTAssertEqual(CloudSaveSync.check(folder: root.path, titleID: id), .noSave, "a folder nobody else writes this game to")
        try Data("DMSYNC1\n".utf8).write(to: root.appendingPathComponent("\(id)/save.dmsync"))
        guard case .hasSave(let date) = CloudSaveSync.check(folder: root.path, titleID: id) else { return XCTFail("the save is there") }
        XCTAssertNotNil(date)
    }

    // ---- the log ----

    func testTheLastResultOfTheLogCounts() {
        let log = """
        launcher: cloud saves through \(drive)/nxnative Saves
        [dm] save sync: on: \(drive)/nxnative Saves/\(id)/save.dmsync
        [dm] save sync: in step with the cloud
        [dm] save sync: this device's save (saved 2026-11-02 21:14:03) changed since the last sync: it goes to the cloud
        [dm] save sync: sent: 3 files, saved 2026-11-02 21:14:03, to \(drive)/nxnative Saves/\(id)/save.dmsync
        """
        XCTAssertEqual(CloudSaveSync.state(fromLog: log), .sent("3 files, saved 2026-11-02 21:14:03"))
    }

    func testEachResult() {
        func state(_ line: String) -> CloudSaveSync.LogState? { CloudSaveSync.state(fromLog: "[dm] save sync: on: /x\n[dm] " + line + "\n") }
        XCTAssertEqual(state("save sync: in step with the cloud"), .inStep)
        XCTAssertEqual(state("save sync: brought in the cloud's save (from iPhone17,1, saved 2026-11-02 08:00:00); this device's is kept in /s-backups/x"), .broughtIn("iPhone17,1"))
        XCTAssertEqual(state("save sync: this device's save (saved 2026-11-02 08:00:00) is not in the cloud yet: it goes to the cloud"), .waitingToSend)
        XCTAssertEqual(state("save sync: the cloud's save /x/save.dmsync cannot be read now; sending later"), .offline)
        XCTAssertEqual(state("save sync: the cloud's save did not come within 8 s"), .offline)
        XCTAssertEqual(state("save sync: no save here or in the cloud yet"), .nothingYet)
        XCTAssertEqual(state("save sync: off: iCloud Drive is not on for this Mac (no /Users/jo/Library/Mobile Documents/com~apple~CloudDocs)"),
                       .off("iCloud Drive is not on for this Mac (no /Users/jo/Library/Mobile Documents/com~apple~CloudDocs)"))
        XCTAssertEqual(state("[RED] save sync: sending to /x/save.dmsync failed (errno=13)"), .failed("sending to /x/save.dmsync failed (errno=13)"))
        XCTAssertNil(CloudSaveSync.state(fromLog: "launcher: saves /s\nfork patches: none\n"), "a session without cloud saves")
    }

    // ---- .dmsync binary format & 3-way merge parity with save_sync.c ----

    func testBinaryArchiveParityWithCSpec() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dmsync-parity-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src")
        let saveDir = srcDir.appendingPathComponent("save")
        let subDir = saveDir.appendingPathComponent("sub")
        let emptyDir = saveDir.appendingPathComponent("empty")
        let devDir = srcDir.appendingPathComponent("save_device")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: devDir, withIntermediateDirectories: true)

        func setMtime(_ url: URL, _ sec: Int) {
            var tv = [timeval(tv_sec: sec, tv_usec: 0), timeval(tv_sec: sec, tv_usec: 0)]
            utimes(url.path, &tv)
        }

        let aURL = saveDir.appendingPathComponent("a")
        try Data("hello".utf8).write(to: aURL)
        setMtime(aURL, 1_000_000_000)

        let bURL = subDir.appendingPathComponent("b")
        try Data("xy".utf8).write(to: bURL)
        _ = "B".withCString { ptr in setxattr(bURL.path, CloudSaveSync.guestXattrName, ptr, 1, 0, XATTR_NOFOLLOW) }
        setMtime(bURL, 1_000_000_100)

        let dURL = devDir.appendingPathComponent("d")
        try Data("dev".utf8).write(to: dURL)
        setMtime(dURL, 1_000_000_050)

        let meta1 = try CloudSaveSync.scan(from: srcDir)
        XCTAssertEqual(meta1.files, 3)
        XCTAssertEqual(meta1.saved, 1_000_000_100)
        XCTAssertEqual(meta1.hash.count, 32)

        let packed = try CloudSaveSync.pack(from: srcDir, titleID: "0100abc")
        let inspected = try CloudSaveSync.inspect(dmsyncData: packed)
        XCTAssertEqual(inspected.hash, meta1.hash)
        XCTAssertEqual(inspected.files, 3)
        XCTAssertEqual(inspected.saved, 1_000_000_100)
        XCTAssertEqual(inspected.title, "0100ABC")
        XCTAssertFalse(inspected.device.isEmpty)

        // Changing mtime or adding Finder's .DS_Store MUST NOT alter the content hash.
        setMtime(aURL, 1_200_000_000)
        try Data("finder".utf8).write(to: saveDir.appendingPathComponent(".DS_Store"))
        let metaMtime = try CloudSaveSync.scan(from: srcDir)
        XCTAssertEqual(metaMtime.hash, meta1.hash)
        XCTAssertEqual(metaMtime.saved, 1_200_000_000)

        // Unpack preserves files, empty dir, device save, guest-name xattr, and mtimes.
        let dstDir = root.appendingPathComponent("dst")
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        _ = try CloudSaveSync.unpack(dmsyncData: packed, into: dstDir)
        XCTAssertEqual(try Data(contentsOf: dstDir.appendingPathComponent("save/a")), Data("hello".utf8))
        XCTAssertEqual(try Data(contentsOf: dstDir.appendingPathComponent("save/sub/b")), Data("xy".utf8))
        XCTAssertEqual(try Data(contentsOf: dstDir.appendingPathComponent("save_device/d")), Data("dev".utf8))
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("save/empty").path, isDirectory: &isDir) && isDir.boolValue)
        var gbuf = [CChar](repeating: 0, count: 16)
        XCTAssertEqual(getxattr(dstDir.appendingPathComponent("save/sub/b").path, CloudSaveSync.guestXattrName, &gbuf, gbuf.count, 0, XATTR_NOFOLLOW), 1)
        XCTAssertEqual(String(cString: gbuf), "B")
        XCTAssertEqual(try CloudSaveSync.scan(from: dstDir).hash, meta1.hash)

        // Corruption & traversal checks.
        XCTAssertThrowsError(try CloudSaveSync.unpack(dmsyncData: packed.dropLast(), into: root.appendingPathComponent("bad1")))
        var extra = packed; extra.append(0)
        XCTAssertThrowsError(try CloudSaveSync.unpack(dmsyncData: extra, into: root.appendingPathComponent("bad2")))
        var flipped = packed; flipped[packed.count - 12] ^= 1
        XCTAssertThrowsError(try CloudSaveSync.unpack(dmsyncData: flipped, into: root.appendingPathComponent("bad3")))

        // Empty directories only -> files == 0 and hash == "" (header hash bytes all 0).
        let emptyOnly = root.appendingPathComponent("emptyOnly")
        try fm.createDirectory(at: emptyOnly.appendingPathComponent("save/e"), withIntermediateDirectories: true)
        let emptyPacked = try CloudSaveSync.pack(from: emptyOnly, titleID: id)
        let emptyInspected = try CloudSaveSync.inspect(dmsyncData: emptyPacked)
        XCTAssertEqual(emptyInspected.files, 0)
        XCTAssertEqual(emptyInspected.hash, "")
    }

    func testSyncNowThreeWayMergeDoesNotClobberEnvAndPrunesBackups() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dmsync-merge-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let macHome = root.appendingPathComponent("mac-home").path
        let cloudFolder = root.appendingPathComponent("cloud-folder").path
        let customFolder = root.appendingPathComponent("custom-cloud").path
        let tid = "010013C00E930000"
        let gameDir = URL(fileURLWithPath: macHome + "/Library/Application Support/nxnative/" + tid)
        let saveDir = gameDir.appendingPathComponent("save")
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cloudFolder, withIntermediateDirectories: true)

        // Custom env.txt must not be overwritten to "icloud" when folder is passed.
        let envURL = gameDir.appendingPathComponent("env.txt")
        let initialEnv = "DM_SAVE_SYNC=\(customFolder)\n"
        try initialEnv.write(to: envURL, atomically: true, encoding: .utf8)

        let localFile = saveDir.appendingPathComponent("user1.dat")
        try Data("v1".utf8).write(to: localFile)
        XCTAssertEqual(String(describing: CloudSaveSync.syncNow(titleID: tid, folder: cloudFolder, home: macHome)).prefix(8), "uploaded")
        XCTAssertEqual(try String(contentsOf: envURL, encoding: .utf8), initialEnv)
        XCTAssertEqual(CloudSaveSync.syncNow(titleID: tid, folder: cloudFolder, home: macHome), .upToDate)

        // Seed 12 old local backups + player folder + cloud backup; next pull prunes to 10 local.
        let backupsDir = gameDir.appendingPathComponent("save-backups")
        for i in 0..<12 {
            let b = backupsDir.appendingPathComponent(String(format: "2001-01-01 00.00.%02d local/save", i))
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: backupsDir.appendingPathComponent("2001-01-01 00.00.00 cloud"), withIntermediateDirectories: true)
        try fm.createDirectory(at: backupsDir.appendingPathComponent("my copy"), withIntermediateDirectories: true)

        // Another device writes v2 into cloudFolder while Mac still matches base (v1) -> Mac pulls & keeps 10 backups.
        let otherSrc = root.appendingPathComponent("other")
        try fm.createDirectory(at: otherSrc.appendingPathComponent("save"), withIntermediateDirectories: true)
        let otherFile = otherSrc.appendingPathComponent("save/user1.dat")
        try Data("v2-from-iphone".utf8).write(to: otherFile)
        let remotePacked = try CloudSaveSync.pack(from: otherSrc, titleID: tid)
        let cloudFile = URL(fileURLWithPath: CloudSaveSync.saveFile(folder: cloudFolder, titleID: tid))
        try fm.createDirectory(at: cloudFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try remotePacked.write(to: cloudFile)

        let pullResult = CloudSaveSync.syncNow(titleID: tid, folder: cloudFolder, home: macHome)
        guard case .downloaded = pullResult else { return XCTFail("Expected download, got \(pullResult)") }
        XCTAssertEqual(try Data(contentsOf: localFile), Data("v2-from-iphone".utf8))
        let backupNames = try fm.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(backupNames.filter { $0.hasSuffix(" local") || $0.contains(" local ") }.count, 10)
        XCTAssertTrue(backupNames.contains("my copy"))
        XCTAssertTrue(backupNames.contains("2001-01-01 00.00.00 cloud"))
    }

    func testSyncNowFailsWithoutOverwritingCorruptOrWrongTitleCloudArchive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dmsync-bad-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let macHome = root.appendingPathComponent("mac-home").path
        let cloudFolder = root.appendingPathComponent("cloud-folder").path
        let tid = "010013C00E930000"
        let gameDir = URL(fileURLWithPath: macHome + "/Library/Application Support/nxnative/" + tid)
        let saveDir = gameDir.appendingPathComponent("save")
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cloudFolder, withIntermediateDirectories: true)
        try Data("local-progress".utf8).write(to: saveDir.appendingPathComponent("user1.dat"))

        let cloudFile = URL(fileURLWithPath: CloudSaveSync.saveFile(folder: cloudFolder, titleID: tid))
        try fm.createDirectory(at: cloudFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. Corrupt bytes in iCloud must fail and never be silently overwritten by local save.
        let corruptBytes = Data("not-a-valid-dmsync-archive".utf8)
        try corruptBytes.write(to: cloudFile)
        let corruptResult = CloudSaveSync.syncNow(titleID: tid, folder: cloudFolder, home: macHome)
        guard case .failed = corruptResult else {
            return XCTFail("Expected .failed for corrupt cloud archive, got \(corruptResult)")
        }
        XCTAssertEqual(try Data(contentsOf: cloudFile), corruptBytes)

        // 2. Archive belonging to another Title ID must also fail without overwriting.
        let otherSrc = root.appendingPathComponent("other-game")
        try fm.createDirectory(at: otherSrc.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("other-save".utf8).write(to: otherSrc.appendingPathComponent("save/slot.dat"))
        let wrongTitleArchive = try CloudSaveSync.pack(from: otherSrc, titleID: "0400486024DEC000")
        try wrongTitleArchive.write(to: cloudFile)

        let wrongTitleResult = CloudSaveSync.syncNow(titleID: tid, folder: cloudFolder, home: macHome)
        guard case .failed = wrongTitleResult else {
            return XCTFail("Expected .failed for wrong-title cloud archive, got \(wrongTitleResult)")
        }
        XCTAssertEqual(try Data(contentsOf: cloudFile), wrongTitleArchive)
    }
}
