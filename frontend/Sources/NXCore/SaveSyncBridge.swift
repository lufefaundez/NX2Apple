import Foundation
import Network

/// Lightweight HTTP save bridge for LAN sync to Apple TV 4K / iOS (dm/host/save_sync_remote.m).
/// Backed directly by Mac iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves/<TITLE_ID>/save.dmsync`).
/// Protects save files via Authorization: Bearer <token> so secrets never enter URLs or logs.
package final class SaveSyncBridge: @unchecked Sendable {
    package static let defaultPort: UInt16 = 47921
    package static let tokenKey = "saveBridgeToken"
    package static let icloudFolder = "nxnative Saves"
    package static let bonjourType = "_nx2apple-saves._tcp"
    private static let maxHeaderBytes = 65_536
    private static let maxBodyBytes = 256 * 1024 * 1024
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    package let port: UInt16
    package let token: String
    private let savesRootOverride: URL?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.nxnative.save-bridge", qos: .utility)
    private let portLock = NSLock()
    private var _boundPort: UInt16
    package var onReady: (@Sendable (UInt16) -> Void)?

    package var boundPort: UInt16 {
        portLock.lock()
        defer { portLock.unlock() }
        return _boundPort
    }

    package init(port: UInt16 = SaveSyncBridge.defaultPort, token: String? = nil,
                 defaults: UserDefaults = .standard, savesRoot: URL? = nil) {
        self.port = port
        self._boundPort = port
        self.savesRootOverride = savesRoot
        if let token, !token.isEmpty {
            self.token = token
        } else if let saved = defaults.string(forKey: Self.tokenKey), !saved.isEmpty {
            self.token = saved
        } else {
            let gen = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            defaults.set(gen, forKey: Self.tokenKey)
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
        return "http://\(host):\(boundPort)/saves/"
    }

    package func fallbackURL() -> String {
        let name = Host.current().name ?? "localhost"
        let host = name.hasSuffix(".local") ? name : "\(name).local"
        return "http://\(host):\(boundPort)/saves/"
    }

    package static func savesRoot(home: String = NSHomeDirectory()) -> URL {
        let resolved = CloudSaveSync.defaultICloudFolder(home: home)
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    package func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let endpointPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: Self.defaultPort)!)
            let l = try NWListener(using: params, on: endpointPort)
            l.service = NWListener.Service(type: Self.bonjourType)
            l.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state, let actual = l.port?.rawValue else { return }
                self.portLock.lock()
                self._boundPort = actual
                let callback = self.onReady
                self.portLock.unlock()
                callback?(actual)
            }
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
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var acc = buffer
            if let content { acc.append(content) }
            if let headerEnd = acc.range(of: Self.headerDelimiter) {
                self.processRequest(acc, headerEnd: headerEnd, connection: connection)
                return
            }
            if acc.count > Self.maxHeaderBytes {
                self.sendResponse(connection, status: 431, message: "Request Header Fields Too Large")
                return
            }
            if error != nil || isComplete || content == nil || content?.isEmpty == true {
                if !acc.isEmpty {
                    self.sendResponse(connection, status: 400, message: "Bad Request")
                } else {
                    connection.cancel()
                }
                return
            }
            self.receiveHeaders(connection, buffer: acc)
        }
    }

    private func processRequest(_ data: Data, headerEnd: Range<Data.Index>, connection: NWConnection) {
        let headerData = data[..<headerEnd.lowerBound]
        let bodyData = Data(data[headerEnd.upperBound...])
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
        let method = String(reqParts[0]).uppercased()
        let rawTarget = String(reqParts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawTarget

        var authHeader: String?
        var rawContentLength: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "authorization" { authHeader = val }
            else if key == "content-length" { rawContentLength = val }
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
        let pathParts = subpath.split(separator: "/", omittingEmptySubsequences: false)
        guard pathParts.count == 2,
              !pathParts[0].isEmpty,
              pathParts[0] != ".",
              pathParts[0] != "..",
              pathParts[1] == "save.dmsync" else {
            sendResponse(connection, status: 400, message: "Invalid Save Path")
            return
        }
        let titleID = String(pathParts[0]).uppercased()
        let root = savesRootOverride ?? Self.savesRoot()
        let gameSaveDir = root.appendingPathComponent(titleID, isDirectory: true)
        let saveFile = gameSaveDir.appendingPathComponent("save.dmsync")

        if method == "GET" {
            guard let fileData = readSaveFile(saveFile) else {
                sendResponse(connection, status: 404, message: "Save Not Found")
                return
            }
            sendDataResponse(connection, data: fileData)
        } else if method == "PUT" {
            guard let rawContentLength else {
                sendResponse(connection, status: 411, message: "Length Required")
                return
            }
            guard let cl = Int(rawContentLength), cl >= 0 else {
                sendResponse(connection, status: 400, message: "Invalid Content-Length")
                return
            }
            guard cl <= Self.maxBodyBytes else {
                sendResponse(connection, status: 413, message: "Payload Too Large")
                return
            }
            if bodyData.count >= cl {
                writeSaveFile(saveFile, inDir: gameSaveDir, data: Data(bodyData.prefix(cl)), connection: connection)
            } else {
                readRemainingBody(connection, totalLength: cl, accumulator: bodyData) { [weak self] finalData in
                    guard let self else { connection.cancel(); return }
                    guard let finalData else {
                        self.sendResponse(connection, status: 400, message: "Truncated Request Body")
                        return
                    }
                    self.writeSaveFile(saveFile, inDir: gameSaveDir, data: finalData, connection: connection)
                }
            }
        } else {
            sendResponse(connection, status: 405, message: "Method Not Allowed")
        }
    }

    private func readRemainingBody(_ connection: NWConnection, totalLength: Int, accumulator: Data,
                                   completion: @escaping (Data?) -> Void) {
        let needed = totalLength - accumulator.count
        guard needed > 0 else {
            completion(Data(accumulator.prefix(totalLength)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(needed, 262_144)) { [weak self] content, _, isComplete, error in
            var acc = accumulator
            if let content { acc.append(content) }
            if acc.count >= totalLength {
                completion(Data(acc.prefix(totalLength)))
            } else if error != nil || isComplete || content == nil || content?.isEmpty == true {
                completion(nil)
            } else if let self {
                self.readRemainingBody(connection, totalLength: totalLength, accumulator: acc, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    private func readSaveFile(_ file: URL) -> Data? {
        let fm = FileManager.default
        let placeholder = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        guard fm.fileExists(atPath: file.path) || fm.fileExists(atPath: placeholder.path) else {
            return nil
        }
        try? fm.startDownloadingUbiquitousItem(at: file)
        var coordError: NSError?
        var loaded: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &coordError) { coordURL in
            loaded = try? Data(contentsOf: coordURL)
        }
        return loaded
    }

    private func writeSaveFile(_ file: URL, inDir dir: URL, data: Data, connection: NWConnection) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { coordURL in
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
                    writeError = error
                }
            }
            if let err = coordError ?? writeError {
                throw err
            }
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
