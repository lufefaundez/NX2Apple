import Foundation
import Network

/// Lightweight HTTP save bridge for LAN sync to Apple TV 4K / iOS (dm/host/save_sync_remote.m).
/// Backed directly by Mac iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves/<TITLE_ID>/save.dmsync`).
/// Protects save files via Authorization: Bearer <token> so secrets never enter URLs or logs.
package final class SaveSyncBridge: @unchecked Sendable {
    package static let defaultPort: UInt16 = 47921
    package static let tokenKey = "saveBridgeToken"
    package static let icloudFolder = "nxnative Saves"

    package let port: UInt16
    package let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.nxnative.save-bridge", qos: .utility)

    package init(port: UInt16 = SaveSyncBridge.defaultPort, token: String? = nil, defaults: UserDefaults = .standard) {
        self.port = port
        if let token, !token.isEmpty {
            self.token = token
        } else if let saved = defaults.string(forKey: Self.tokenKey), !saved.isEmpty {
            self.token = saved
        } else {
            let gen = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            self.token = gen
        }
    }

    package static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) && (flags & IFF_LOOPBACK) == 0 {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.isEmpty && ip != "127.0.0.1" { return ip }
                    }
                }
            }
        }
        return nil
    }

    package func primaryURL() -> String {
        let host = Self.localIPAddress() ?? "127.0.0.1"
        return "http://\(host):\(port)/saves/"
    }

    package func fallbackURL() -> String {
        let name = Host.current().name ?? "localhost"
        let host = name.hasSuffix(".local") ? name : "\(name).local"
        return "http://\(host):\(port)/saves/"
    }

    package static func savesRoot(home: String = NSHomeDirectory()) -> URL {
        let base = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: base + "/NX Save data") {
            return URL(fileURLWithPath: base + "/NX Save data", isDirectory: true)
        }
        return URL(fileURLWithPath: base + "/" + icloudFolder, isDirectory: true)
    }

    package func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.service = NWListener.Service(type: "_nx2apple-saves._tcp")
            l.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            l.stateUpdateHandler = { _ in }
            l.start(queue: queue)
            self.listener = l
        } catch {
            // Port might be in use by another instance or launch agent; non-fatal
        }
    }

    package func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, _ in
            guard let self, let data = content, !data.isEmpty else {
                connection.cancel()
                return
            }
            self.processRequest(data, connection: connection)
        }
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            sendResponse(connection, status: 400, message: "Bad Request")
            return
        }
        let headerData = data[..<headerEnd.lowerBound]
        let bodyData = data[headerEnd.upperBound...]
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            sendResponse(connection, status: 400, message: "Bad Request")
            return
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else {
            sendResponse(connection, status: 400, message: "Bad Request")
            return
        }
        let reqParts = reqLine.split(separator: " ")
        guard reqParts.count >= 2 else {
            sendResponse(connection, status: 400, message: "Bad Request")
            return
        }
        let method = String(reqParts[0])
        let path = String(reqParts[1])

        var authHeader: String?
        var contentLength: Int?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("authorization:") {
                authHeader = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }

        let expectedAuth = "Bearer \(token)"
        guard authHeader == expectedAuth else {
            sendResponse(connection, status: 401, message: "Unauthorized")
            return
        }

        guard path.hasPrefix("/saves/") else {
            sendResponse(connection, status: 404, message: "Not Found")
            return
        }
        let subpath = String(path.dropFirst("/saves/".count))
        let pathParts = subpath.split(separator: "/")
        guard pathParts.count == 2, pathParts[1] == "save.dmsync" else {
            sendResponse(connection, status: 400, message: "Invalid Save Path")
            return
        }
        let titleID = String(pathParts[0]).uppercased()
        let gameSaveDir = Self.savesRoot().appendingPathComponent(titleID, isDirectory: true)
        let saveFile = gameSaveDir.appendingPathComponent("save.dmsync")

        if method == "GET" {
            guard FileManager.default.fileExists(atPath: saveFile.path),
                  let fileData = try? Data(contentsOf: saveFile) else {
                sendResponse(connection, status: 404, message: "Save Not Found")
                return
            }
            sendDataResponse(connection, data: fileData)
        } else if method == "PUT" {
            if let cl = contentLength, bodyData.count < cl {
                let fullBody = Data(bodyData)
                readRemainingBody(connection, expected: cl - bodyData.count, accumulator: fullBody) { [weak self] finalData in
                    guard let self else { return }
                    self.writeSaveFile(saveFile, inDir: gameSaveDir, data: finalData, connection: connection)
                }
            } else {
                writeSaveFile(saveFile, inDir: gameSaveDir, data: Data(bodyData), connection: connection)
            }
        } else {
            sendResponse(connection, status: 405, message: "Method Not Allowed")
        }
    }

    private func readRemainingBody(_ connection: NWConnection, expected: Int, accumulator: Data, completion: @escaping (Data) -> Void) {
        var acc = accumulator
        connection.receive(minimumIncompleteLength: 1, maximumLength: expected) { [weak self] content, _, _, _ in
            if let c = content { acc.append(c) }
            if acc.count >= expected {
                completion(acc)
            } else if let self, let c = content, !c.isEmpty {
                self.readRemainingBody(connection, expected: expected - c.count, accumulator: acc, completion: completion)
            } else {
                completion(acc)
            }
        }
    }

    private func writeSaveFile(_ file: URL, inDir dir: URL, data: Data, connection: NWConnection) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tempFile = dir.appendingPathComponent("save.dmsync.tmp.\(UUID().uuidString)")
            try data.write(to: tempFile, options: .atomic)
            _ = try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tempFile, to: file)
            sendResponse(connection, status: 200, message: "OK")
        } catch {
            sendResponse(connection, status: 500, message: "Write Error: \(error.localizedDescription)")
        }
    }

    private func sendResponse(_ connection: NWConnection, status: Int, message: String) {
        let resp = "HTTP/1.1 \(status) \(message)\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n\(message)"
        connection.send(content: Data(resp.utf8), completion: .contentProcessed({ _ in connection.cancel() }))
    }

    private func sendDataResponse(_ connection: NWConnection, data: Data) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        var full = Data(headers.utf8)
        full.append(data)
        connection.send(content: full, completion: .contentProcessed({ _ in connection.cancel() }))
    }
}
