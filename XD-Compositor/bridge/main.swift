import AppKit
import Network
import ApplicationServices

struct EditJob: Codable {
    var id: String
    var source: String
    var document: String
    var node: String
    var asset: String
    var title: String
    var project: String
    var seen: String
    var revision = ""
    var output = ""
    var pending = false
    var status = "watching"
}

final class Bridge: NSObject, NSApplicationDelegate {
    private var listener: NWListener?
    private var token = ""
    private var jobs = [String: EditJob]()
    private var stateURL: URL!
    private var timer: Timer?
    private var rendering = Set<String>()
    private var changedAt = [String: Date]()
    private var automaticUntil = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var diagnostic = "idle"
    private var windowTitles = [String]()
    private var returningTo: NSRunningApplication?
    private let networkQueue = DispatchQueue(label: "xd.compositor.http")
    private let renderQueue = DispatchQueue(label: "xd.compositor.render")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = config["token"] as? String,
              let port = config["port"] as? UInt16, secret.count >= 32 else { NSApp.terminate(nil); return }
        token = secret
        stateURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("jobs.json")
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode([String: EditJob].self, from: data) {
            jobs = saved.filter { validSource(URL(fileURLWithPath: $0.value.source)) }
        }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: parameters)
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.networkQueue)
                self.receive(connection, buffered: Data())
                self.networkQueue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
            }
            listener?.stateUpdateHandler = { state in
                if case .failed = state { DispatchQueue.main.async { NSApp.terminate(nil) } }
            }
            listener?.start(queue: networkQueue)
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        } catch { NSApp.terminate(nil) }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var all = buffered
            if let data { all.append(data) }
            guard all.count < 65536, error == nil else { connection.cancel(); return }
            if let range = all.range(of: Data("\r\n\r\n".utf8)), let header = String(data: all[..<range.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 { result[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
                let route = lines.first?.split(separator: " ")
                guard route?.count == 3, route?[0] == "POST", route?[2] == "HTTP/1.1",
                      headers["authorization"] == "Bearer " + self.token,
                      let length = Int(headers["content-length"] ?? ""), length > 0, length < 8192 else {
                    self.reply(connection, code: 403); return
                }
                if all.count >= range.upperBound + length {
                    let body = all.subdata(in: range.upperBound..<(range.upperBound + length))
                    let path = String(route![1])
                    DispatchQueue.main.async { self.handle(path, body: body, connection: connection) }
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, buffered: all) }
        }
    }

    private func validSource(_ file: URL) -> Bool {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Adobe/UXP/PluginsStorage/SPRK/").path + "/"
        return resolved.path == file.standardizedFileURL.path && resolved.path.hasPrefix(root)
            && resolved.pathComponents.contains("CmptXd01") && resolved.pathComponents.contains("PluginData")
            && resolved.pathComponents.contains(where: { $0.hasPrefix("compositor-edit-") })
            && resolved.lastPathComponent.hasPrefix("working-") && ["png", "jpg", "gif"].contains(resolved.pathExtension.lowercased())
            && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func handle(_ path: String, body: Data, connection: NWConnection) {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: String] else { reply(connection, code: 400); return }
        switch path {
        case "/edit":
            guard let raw = request["file"], validSource(URL(fileURLWithPath: raw)) else { reply(connection, code: 403); return }
            guard let editor = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.storyteller.photocraft").first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.storyteller.photocraft") else { reply(connection, code: 500); return }
            do {
                let file = URL(fileURLWithPath: raw).standardizedFileURL
                let folder = file.deletingLastPathComponent()
                let metaData = try Data(contentsOf: folder.appendingPathComponent("session.json"))
                guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: String],
                      let document = meta["document"], let node = meta["node"], let asset = meta["asset"],
                      meta["filename"] == file.lastPathComponent,
                      folder.lastPathComponent == "compositor-edit-" + document + "-" + node else { reply(connection, code: 400); return }
                let id = UUID().uuidString
                let project = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".psd")
                try PSDWorkFile.create(source: file, destination: project)
                // A new edit session supersedes an earlier one for this object; never delete its user's project.
                jobs = jobs.filter { $0.value.document != document || $0.value.node != node }
                jobs[id] = EditJob(id: id, source: file.path, document: document, node: node, asset: asset,
                                  title: self.xdWindowTitle() ?? request["title"] ?? "", project: project.path, seen: fingerprint(project))
                saveState()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([project], withApplicationAt: editor, configuration: configuration) { app, error in
                    self.reply(connection, code: error == nil ? 200 : 500)
                    guard error == nil, let app else { return }
                    // Let XD finish its plugin command before transferring keyboard focus.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        guard front == "com.adobe.xd" || front == app.bundleIdentifier else { return }
                        app.activate(options: [])
                        if AXIsProcessTrusted() {
                            let element = AXUIElementCreateApplication(app.processIdentifier)
                            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                            if let window = self.attribute(element, kAXFocusedWindowAttribute) {
                                AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
                            }
                        }
                    }
                }
            } catch { reply(connection, code: 500, payload: ["error": error.localizedDescription]) }
        case "/pending":
            guard let document = request["document"] else { reply(connection, code: 400); return }
            if let title = request["title"] {
                for id in Array(jobs.keys) where jobs[id]?.document == document { jobs[id]?.title = self.xdWindowTitle() ?? title }
            }
            let pending = jobs.values.filter { $0.document == document && $0.pending }.map { job in
                ["id": job.id, "folder": URL(fileURLWithPath: job.source).deletingLastPathComponent().lastPathComponent,
                 "node": job.node, "asset": job.asset, "revision": job.revision, "filename": job.output]
            }
            reply(connection, payload: ["automatic": automaticUntil > Date(), "updates": pending])
        case "/ack":
            guard let id = request["id"], var job = jobs[id] else { reply(connection, code: 409); return }
            if let asset = request["asset"], job.asset == request["previous"] { job.asset = asset }
            if job.revision == request["revision"] {
                job.pending = false
                job.status = request["status"] ?? "applied"
            }
            jobs[id] = job
            saveState()
            if !job.pending, let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: job.source).deletingLastPathComponent(), includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("result-") && file.pathExtension == "png" && file.lastPathComponent != job.output {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            reply(connection)
            restoreFocus()
        case "/status":
            reply(connection, payload: ["accessibility": AXIsProcessTrusted(), "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "diagnostic": diagnostic, "titles": windowTitles, "jobs": jobs.values.map { job in
                ["id": job.id, "document": job.document, "node": job.node, "project": job.project,
                 "status": job.status, "pending": job.pending, "revision": job.revision, "output": job.output]
            }])
        default: reply(connection, code: 404)
        }
    }

    private func convertProject(source: URL, destination: URL) throws {
        guard source.pathExtension == "comp" else {
            try PSDWorkFile.render(source: source, destination: destination)
            return
        }
        let task = Process()
        task.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/XDCompositorRenderer")
        task.arguments = [source.path, destination.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NSError(domain: "Bridge", code: Int(task.terminationStatus)) }
    }

    private func fingerprint(_ project: URL) -> String {
        let watched = project.pathExtension == "comp" ? project.appendingPathComponent("manifest.json") : project
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: watched.path),
              let date = attrs[.modificationDate] as? Date else { return "" }
        return "\(date.timeIntervalSince1970)-\(attrs[.systemFileNumber] ?? 0)-\(attrs[.size] ?? 0)"
    }

    private func tick() {
        for id in Array(jobs.keys) {
            guard var job = jobs[id] else { continue }
            let current = fingerprint(URL(fileURLWithPath: job.project))
            if !current.isEmpty && current != job.seen {
                job.seen = current
                job.status = "saving"
                jobs[id] = job
                changedAt[id] = Date()
                saveState()
            }
            if let date = changedAt[id], Date().timeIntervalSince(date) >= 0.7, !rendering.contains(id) {
                changedAt.removeValue(forKey: id)
                render(job)
            }
        }
        if Date().timeIntervalSince(lastAttempt) >= 8, let job = jobs.values.first(where: { $0.pending }) {
            lastAttempt = Date()
            triggerUpdate(job)
        }
        if automaticUntil < Date() { restoreFocus() }
    }

    private func render(_ job: EditJob) {
        rendering.insert(job.id)
        let output = URL(fileURLWithPath: job.source).deletingLastPathComponent().appendingPathComponent("result-" + UUID().uuidString + ".png")
        renderQueue.async {
            var success = false
            do {
                try self.convertProject(source: URL(fileURLWithPath: job.project), destination: output)
                success = true
            } catch {}
            DispatchQueue.main.async {
                self.rendering.remove(job.id)
                guard var current = self.jobs[job.id] else { try? FileManager.default.removeItem(at: output); return }
                if current.seen != job.seen {
                    try? FileManager.default.removeItem(at: output)
                    self.changedAt[job.id] = Date()
                    return
                }
                if success {
                    current.output = output.lastPathComponent
                    current.revision = UUID().uuidString
                    current.pending = true
                    current.status = "pending"
                    self.jobs[job.id] = current
                    self.saveState()
                    self.lastAttempt = .distantPast
                } else {
                    try? FileManager.default.removeItem(at: output)
                    current.status = "render-error"
                    self.jobs[job.id] = current
                    self.saveState()
                }
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result != .success { diagnostic = "ax-attribute-\(name)-\(result.rawValue)" }
        return result == .success ? value : nil
    }
    private func find(_ element: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
        if attribute(element, kAXTitleAttribute) as? String == title { return element }
        guard depth < 8, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children { if let result = find(child, title: title, depth: depth + 1) { return result } }
        return nil
    }

    private func xdWindowTitle() -> String? {
        guard AXIsProcessTrusted(), let xd = NSRunningApplication.runningApplications(withBundleIdentifier: "com.adobe.xd").first,
              let focused = attribute(xdAccessibility(xd), kAXFocusedWindowAttribute),
              let title = attribute(focused as! AXUIElement, kAXTitleAttribute) as? String, !title.isEmpty else { return nil }
        return title
    }

    private func xdAccessibility(_ xd: NSRunningApplication) -> AXUIElement {
        let app = AXUIElementCreateApplication(xd.processIdentifier)
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var enabled: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, name as CFString, &enabled) != .success || enabled as? Bool != true {
                AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
            }
        }
        return app
    }

    private func triggerUpdate(_ job: EditJob) {
        guard AXIsProcessTrusted() else { diagnostic = "permission-required"; return }
        guard let xd = NSRunningApplication.runningApplications(withBundleIdentifier: "com.adobe.xd").first else { diagnostic = "xd-closed"; return }
        let app = xdAccessibility(xd)
        var windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        // AXWindows can omit windows on another desktop; focused/main windows still identify them.
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
            }
        }
        windowTitles = windows.map { attribute($0, kAXTitleAttribute) as? String ?? "<untitled>" }
        guard let window = windows.first(where: { (attribute($0, kAXTitleAttribute) as? String)?.contains(job.title) == true && !job.title.isEmpty }) ?? (windows.count == 1 ? windows.first : nil) else {
            diagnostic = "document-closed"; restoreFocus(); return
        }
        guard !(attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains(where: { attribute($0, kAXRoleAttribute) as? String == "AXSheet" }) else { diagnostic = "xd-dialog"; return }
        returningTo = returningTo ?? NSWorkspace.shared.frontmostApplication
        automaticUntil = Date().addingTimeInterval(5)
        xd.activate(options: [])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        // Menu validation follows activation asynchronously in XD.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let bar = self.attribute(app, kAXMenuBarAttribute) else { return }
            let menuBar = bar as! AXUIElement
            guard let plugins = self.find(menuBar, title: "插件") ?? self.find(menuBar, title: "Plugins") else { self.diagnostic = "plugins-menu-missing"; return }
            AXUIElementPerformAction(plugins, kAXPressAction as CFString)
            if let submenu = self.find(plugins, title: "PhotoCraft") { AXUIElementPerformAction(submenu, kAXPressAction as CFString) }
            if let command = self.find(menuBar, title: "更新回 XD") {
                let result = AXUIElementPerformAction(command, kAXPressAction as CFString)
                self.diagnostic = "command-\(result.rawValue)"
            } else { self.diagnostic = "update-menu-missing" }
        }
    }

    private func restoreFocus() {
        guard let previous = returningTo else { return }
        returningTo = nil
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.adobe.xd", previous.bundleIdentifier != "com.adobe.xd" {
            previous.activate(options: [])
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }
    }
    private func reply(_ connection: NWConnection, code: Int = 200, payload: [String: Any] = ["ok": true]) {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(code) Result\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

let application = NSApplication.shared
let delegate = Bridge()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
