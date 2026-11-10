import Darwin
import Foundation
import XCTest
@testable import NXCore

final class SaveSyncBridgeTests: XCTestCase {
    private var root: URL!
    private var bridge: SaveSyncBridge?
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("save-bridge-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testDefaults = TestDefaults.make("save-bridge-tests")
    }

    override func tearDownWithError() throws {
        bridge?.stop()
        bridge = nil
        testDefaults = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func startBridge(token: String = "bridge-secret") throws -> (SaveSyncBridge, UInt16) {
        let ready = expectation(description: "bridge ready")
        let b = SaveSyncBridge(port: 0, token: token, defaults: testDefaults, savesRoot: root)
        b.onReady = { _ in ready.fulfill() }
        b.start()
        wait(for: [ready], timeout: 5)
        self.bridge = b
        return (b, b.boundPort)
    }

    func testTokenIsPersistedInDefaultsAcrossInstances() {
        let first = SaveSyncBridge(defaults: testDefaults, savesRoot: root)
        let second = SaveSyncBridge(defaults: testDefaults, savesRoot: root)
        XCTAssertFalse(first.token.isEmpty)
        XCTAssertEqual(first.token, second.token)
    }

    func testMultiChunkPutGetAndBearerAuth() async throws {
        let (_, port) = try startBridge(token: "top-secret")
        let tid = "010013C00E930000"
        let url = URL(string: "http://127.0.0.1:\(port)/saves/\(tid)/save.dmsync")!

        // Unauthenticated GET -> 401
        let unauthReq = URLRequest(url: url)
        let (_, unauthResp) = try await URLSession.shared.data(for: unauthReq)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 401)

        // Missing save GET -> 404
        var getReq = URLRequest(url: url)
        getReq.setValue("Bearer top-secret", forHTTPHeaderField: "Authorization")
        let (_, notFoundResp) = try await URLSession.shared.data(for: getReq)
        XCTAssertEqual((notFoundResp as? HTTPURLResponse)?.statusCode, 404)

        // Large payload (> 65536 bytes to force multi-chunk readRemainingBody!)
        let payload = Data((0..<260_000).map { UInt8($0 & 0xFF) })
        var putReq = URLRequest(url: url)
        putReq.httpMethod = "PUT"
        putReq.httpBody = payload
        putReq.setValue("Bearer top-secret", forHTTPHeaderField: "Authorization")
        putReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, putResp) = try await URLSession.shared.data(for: putReq)
        XCTAssertEqual((putResp as? HTTPURLResponse)?.statusCode, 200)

        let diskFile = root.appendingPathComponent("\(tid)/save.dmsync")
        XCTAssertEqual(try Data(contentsOf: diskFile), payload)

        // Authenticated GET returns exact 260 KB payload.
        let (gotData, okResp) = try await URLSession.shared.data(for: getReq)
        XCTAssertEqual((okResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(gotData, payload)
    }

    func testTruncatedPutDoesNotOverwriteExistingSave() throws {
        let (_, port) = try startBridge(token: "top-secret")
        let tid = "010013C00E930000"
        let gameDir = root.appendingPathComponent(tid, isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let saveFile = gameDir.appendingPathComponent("save.dmsync")
        let original = Data("original-good-save".utf8)
        try original.write(to: saveFile)

        // Open raw TCP socket, send PUT claiming 50000 bytes, send 16 bytes, then shutdown(SHUT_WR)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)

        let reqHead = "PUT /saves/\(tid)/save.dmsync HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer top-secret\r\nContent-Length: 50000\r\n\r\npartial-16-bytes"
        _ = reqHead.withCString { ptr in Darwin.send(fd, ptr, Int(strlen(ptr)), 0) }
        shutdown(fd, SHUT_WR)

        var respBuf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.recv(fd, &respBuf, respBuf.count, 0)
        let respText = n > 0 ? String(decoding: respBuf.prefix(n), as: UTF8.self) : ""
        XCTAssertTrue(respText.hasPrefix("HTTP/1.1 400 "), "Expected 400 for truncated body, got: \(respText)")
        XCTAssertEqual(try Data(contentsOf: saveFile), original)
    }
}
