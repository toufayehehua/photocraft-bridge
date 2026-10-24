import AppKit
import Network
import ImageIO
import UniformTypeIdentifiers

private let imageLimit = 64 * 1024 * 1024
private let requestLimit = 96 * 1024 * 1024
private let bridgePort: UInt16 = 47836

private struct Job: Codable {
    let id: String
    let document: String
    let node: String
    var asset: String
    let name: String
    let sourceExtension: String
    var seen: String
    var revision = ""
    var pending = false
    var status = "watching"
    var awaitingAck = [String]()
    var active: Bool { !["stale", "deleted", "superseded", "open-error"].contains(status) }
}

private final class RequestBuffer {
    var data = Data()
    var bodyOffset: Int?
    var length = 0
    var path = ""
}

private final class Bridge: NSObject, NSApplicationDelegate {
    private var listener: NWListener?
    private var timer: Timer?
    private var token = ""
    private var port: UInt16 = 0
    private var root: URL!
    private var projects: URL!
    private var jobs = [String: Job]()
    private var changedAt = [String: Date]()
    private var rendering = Set<String>()
    private let networkQueue = DispatchQueue(label: "figma.photocraft.http")
    private let workQueue = DispatchQueue(label: "figma.photocraft.images")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let background = arguments.count == 2
        let configURL = background ? URL(fileURLWithPath: arguments[1])
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Figma-PhotoCraft/bridge-config.json")
        guard arguments.count <= 2,
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = config["token"] as? String,
              secret.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let configuredPort = config["port"] as? UInt16, configuredPort == bridgePort else {
            if !background {
                let alert = NSAlert()
                alert.messageText = "请先安装 Figma PhotoCraft Bridge"
                alert.runModal()
            }
            NSApp.terminate(nil); return
        }
        if !background {
            showPairingCode(secret)
            NSApp.terminate(nil); return
        }
        token = secret; port = configuredPort
        root = configURL.deletingLastPathComponent()
        projects = root.appendingPathComponent("projects", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if let data = try? Data(contentsOf: root.appendingPathComponent("jobs.json")),
               let saved = try? JSONDecoder().decode([String: Job].self, from: data) {
                jobs = saved.filter { key, job in
                    key == job.id && UUID(uuidString: key) != nil && ["png", "jpg", "gif"].contains(job.sourceExtension)
                        && ownedFile(folder(job).appendingPathComponent("working.psd"))
                        && (job.revision.isEmpty || UUID(uuidString: job.revision) != nil)
                        && job.awaitingAck.allSatisfy { UUID(uuidString: $0) != nil }
                }
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: parameters)
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.networkQueue)
                self.receive(connection, buffer: RequestBuffer())
                self.networkQueue.asyncAfter(deadline: .now() + 120) { connection.cancel() }
            }
            listener?.stateUpdateHandler = { state in
                if case .failed = state { DispatchQueue.main.async { NSApp.terminate(nil) } }
            }
            listener?.start(queue: networkQueue)
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        } catch { NSApp.terminate(nil) }
    }

    private func showPairingCode(_ code: String) {
        let alert = NSAlert()
        alert.messageText = "配对码"
        let field = NSTextField(string: code)
        field.frame = NSRect(x: 0, y: 0, width: 540, height: 24)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "复制配对码")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !token.isEmpty { showPairingCode(token) }
        return false
    }

    private func receive(_ connection: NWConnection, buffer: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            if let data { buffer.data.append(data) }
            guard buffer.data.count <= requestLimit + 16384 else { self.reply(connection, code: 413); return }
            if buffer.bodyOffset == nil {
                if let separator = buffer.data.range(of: Data("\r\n\r\n".utf8)) {
                    guard separator.upperBound <= 16384,
                          let header = String(data: buffer.data[..<separator.lowerBound], encoding: .utf8) else { self.reply(connection, code: 400); return }
                    let lines = header.components(separatedBy: "\r\n")
                    let route = lines.first?.split(separator: " ").map(String.init) ?? []
                    guard route.count == 3, route[2] == "HTTP/1.1", route[1].count < 64 else { self.reply(connection, code: 400); return }
                    var headers = [String: String]()
                    for line in lines.dropFirst() {
                        let pair = line.split(separator: ":", maxSplits: 1)
                        guard pair.count == 2 else { self.reply(connection, code: 400); return }
                        let key = pair[0].lowercased()
                        guard headers[key] == nil else { self.reply(connection, code: 400); return }
                        headers[key] = pair[1].trimmingCharacters(in: .whitespaces)
                    }
                    guard ["127.0.0.1:\(self.port)", "localhost:\(self.port)"].contains(headers["host"]?.lowercased() ?? ""),
                          headers["transfer-encoding"] == nil else { self.reply(connection, code: 400); return }
                    if route[0] == "OPTIONS" { self.reply(connection, code: 204); return }
                    guard route[0] == "POST" else { self.reply(connection, code: 405); return }
                    guard self.authorized(headers["authorization"] ?? "") else { self.reply(connection, code: 403); return }
                    guard let length = Int(headers["content-length"] ?? ""), length > 0 else { self.reply(connection, code: 400); return }
                    guard length <= requestLimit else { self.reply(connection, code: 413); return }
                    guard ["/edit", "/pending", "/image", "/ack", "/status"].contains(route[1]) else { self.reply(connection, code: 404); return }
                    buffer.bodyOffset = separator.upperBound; buffer.length = length; buffer.path = route[1]
                } else if buffer.data.count >= 16384 { self.reply(connection, code: 431); return }
            }
            if let offset = buffer.bodyOffset, buffer.data.count >= offset + buffer.length {
                guard buffer.data.count == offset + buffer.length else { self.reply(connection, code: 400); return }
                let body = buffer.data.subdata(in: offset..<(offset + buffer.length))
                self.workQueue.async {
                    guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: String] else { self.reply(connection, code: 400); return }
                    DispatchQueue.main.async { self.handle(buffer.path, request: request, connection: connection) }
                }
            } else if complete { connection.cancel() }
            else { self.receive(connection, buffer: buffer) }
        }
    }

    private func authorized(_ value: String) -> Bool {
        let expected = Array(("Bearer " + token).utf8), actual = Array(value.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func handle(_ path: String, request: [String: String], connection: NWConnection) {
        switch path {
        case "/edit": edit(request, connection: connection)
        case "/pending":
            guard let document = field(request, "document") else { reply(connection, code: 400); return }
            let updates = jobs.values.filter { $0.document == document && $0.active && $0.pending }.sorted { $0.id < $1.id }.map {
                ["id": $0.id, "node": $0.node, "asset": $0.asset, "revision": $0.revision]
            }
            reply(connection, payload: ["updates": updates])
        case "/image":
            guard let id = field(request, "id"), var job = jobs[id], let revision = field(request, "revision"),
                  UUID(uuidString: revision) != nil else { reply(connection, code: 400); return }
            guard job.revision == revision else { reply(connection, code: 409); return }
            let file = result(job, revision: revision)
            guard ownedFile(file), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= imageLimit, let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) else { reply(connection, code: 404); return }
            if !job.awaitingAck.contains(revision) { job.awaitingAck.append(revision); jobs[id] = job; saveState() }
            reply(connection, bytes: bytes, type: "image/png")
        case "/ack":
            guard let id = field(request, "id"), var job = jobs[id], let revision = field(request, "revision"),
                  UUID(uuidString: revision) != nil else { reply(connection, code: 400); return }
            if let asset = field(request, "asset"), job.asset == request["previous"] { job.asset = asset }
            job.awaitingAck.removeAll { $0 == revision }
            if job.revision == revision {
                job.pending = false
                job.status = field(request, "status") ?? "applied"
            }
            jobs[id] = job; saveState(); cleanup(job)
            reply(connection)
        case "/status":
            let status = jobs.values.sorted { $0.id < $1.id }.map {
                ["id": $0.id, "document": $0.document, "node": $0.node, "asset": $0.asset,
                 "status": $0.status, "revision": $0.revision, "pending": $0.pending] as [String: Any]
            }
            reply(connection, payload: ["version": "1.1.0", "build": 3, "jobs": status])
        default: reply(connection, code: 404)
        }
    }

    private func edit(_ request: [String: String], connection: NWConnection) {
        guard let document = field(request, "document"), let node = field(request, "node"),
              let asset = field(request, "asset"), let image = request["image"], image.utf8.count <= ((imageLimit + 2) / 3) * 4,
              let editor = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.storyteller.photocraft").first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.storyteller.photocraft") else { reply(connection, code: 400); return }
        let id = UUID().uuidString, name = String((request["name"] ?? "").prefix(1024)), projectRoot = projects!
        workQueue.async {
            let folder = projectRoot.appendingPathComponent(id, isDirectory: true)
            do {
                guard let bytes = Data(base64Encoded: image), !bytes.isEmpty, bytes.count <= imageLimit,
                      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let kind = CGImageSourceGetType(source) as String?,
                      let ext = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpg", UTType.gif.identifier: "gif"][kind] else { throw NSError(domain: "FigmaPhotoCraft", code: 400) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let original = folder.appendingPathComponent("source." + ext), project = folder.appendingPathComponent("working.psd")
                try bytes.write(to: original, options: .atomic)
                try PSDWorkFile.create(source: original, destination: project)
                let job = Job(id: id, document: document, node: node, asset: asset, name: name,
                    sourceExtension: ext, seen: self.fingerprint(project))
                DispatchQueue.main.async {
                    for oldID in Array(self.jobs.keys) where self.jobs[oldID]?.document == document && self.jobs[oldID]?.node == node {
                        self.jobs[oldID]?.status = "superseded"; self.jobs[oldID]?.pending = false
                    }
                    self.jobs[id] = job; self.saveState()
                    let config = NSWorkspace.OpenConfiguration(); config.activates = true
                    NSWorkspace.shared.open([project], withApplicationAt: editor, configuration: config) { _, error in
                        DispatchQueue.main.async {
                            if error != nil { self.jobs[id]?.status = "open-error"; self.saveState() }
                            self.reply(connection, code: error == nil ? 200 : 500, payload: error == nil ? ["id": id] : ["error": "open-failed"])
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                self.reply(connection, code: 400, payload: ["error": "invalid-image"])
            }
        }
    }

    private func tick() {
        for id in Array(jobs.keys) {
            guard var job = jobs[id], job.active else { continue }
            let current = fingerprint(folder(job).appendingPathComponent("working.psd"))
            if !current.isEmpty && current != job.seen {
                job.seen = current; job.status = "saving"; jobs[id] = job
                changedAt[id] = Date(); saveState()
            }
            if let date = changedAt[id], Date().timeIntervalSince(date) >= 0.7, !rendering.contains(id) {
                changedAt.removeValue(forKey: id); render(job)
            }
        }
    }

    private func render(_ job: Job) {
        rendering.insert(job.id)
        let revision = UUID().uuidString, source = folder(job).appendingPathComponent("working.psd")
        let output = result(job, revision: revision)
        workQueue.async {
            var success = false
            do {
                guard self.ownedFile(source) else { throw NSError(domain: "FigmaPhotoCraft", code: 400) }
                try PSDWorkFile.render(source: source, destination: output)
                let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                success = size > 0 && size <= imageLimit
            } catch {}
            let seen = self.fingerprint(source)
            DispatchQueue.main.async {
                self.rendering.remove(job.id)
                guard var current = self.jobs[job.id], current.active else { try? FileManager.default.removeItem(at: output); return }
                guard current.seen == job.seen, seen == job.seen else {
                    try? FileManager.default.removeItem(at: output)
                    if !seen.isEmpty { current.seen = seen; current.status = "saving"; self.jobs[job.id] = current }
                    self.changedAt[job.id] = Date(); self.saveState(); return
                }
                if success {
                    current.revision = revision; current.pending = true; current.status = "pending"
                } else { try? FileManager.default.removeItem(at: output); current.status = "render-error" }
                self.jobs[job.id] = current; self.saveState(); self.cleanup(current)
            }
        }
    }

    private func field(_ request: [String: String], _ key: String) -> String? {
        guard let value = request[key], !value.isEmpty, value.utf8.count <= 4096 else { return nil }
        return value
    }
    private func folder(_ job: Job) -> URL { projects.appendingPathComponent(job.id, isDirectory: true) }
    private func result(_ job: Job, revision: String) -> URL { folder(job).appendingPathComponent("result-" + revision + ".png") }
    private func ownedFile(_ file: URL) -> Bool {
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL
        return canonical == file.standardizedFileURL && canonical.path.hasPrefix(projects.path + "/")
            && (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    private func fingerprint(_ file: URL) -> String {
        guard ownedFile(file), let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else { return "" }
        return "\(modified.timeIntervalSince1970)-\(attributes[.systemFileNumber] ?? 0)-\(attributes[.size] ?? 0)"
    }
    private func cleanup(_ job: Job) {
        let kept = Set(([job.revision] + job.awaitingAck).map { "result-" + $0 + ".png" })
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder(job), includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("result-") && file.pathExtension == "png" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func saveState() {
        let file = root.appendingPathComponent("jobs.json")
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    private func reply(_ connection: NWConnection, code: Int = 200, payload: [String: Any] = ["ok": true]) {
        reply(connection, code: code, bytes: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8), type: "application/json")
    }
    private func reply(_ connection: NWConnection, code: Int = 200, bytes: Data, type: String) {
        let body = code == 204 ? Data() : bytes
        let header = "HTTP/1.1 \(code) Result\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

let application = NSApplication.shared
private let delegate = Bridge()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
