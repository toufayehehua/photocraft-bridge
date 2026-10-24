import AppKit
import Darwin
import Security

private enum SetupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

private enum Host: String {
    case figma, xd
    var stateName: String { self == .figma ? "Figma-PhotoCraft" : "XD-Compositor" }
    var appName: String { self == .figma ? "Figma PhotoCraft Bridge.app" : "XD Compositor Bridge.app" }
    var identity: String { self == .figma ? "local.figma.photocraft.bridge" : "local.xd.compositor.bridge" }
    var executable: String { self == .figma ? "FigmaPhotoCraftBridge" : "XDCompositorBridge" }
    var minimumOS: Int { self == .figma ? 11 : 26 }
}

private struct Configuration: Codable {
    let port: Int
    let token: String
}

private struct FileSnapshot {
    let url: URL
    let data: Data?
    let permissions: NSNumber?
}

private final class BridgeStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func setReady() { lock.lock(); value = true; lock.unlock() }
    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func runCommand(_ arguments: [String], required: Bool = true) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: arguments[0])
    task.arguments = Array(arguments.dropFirst())
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
    if required && task.terminationStatus != 0 { throw SetupError.invalid("无法启动或验证桥接组件。") }
}

private final class Installer {
    let host: Host
    let resources: URL
    let home: URL
    let runner: ([String], Bool) throws -> Void
    let healthCheck: ((Configuration) throws -> Void)?
    private let files = FileManager.default
    private var snapshots = [FileSnapshot]()
    private var shortcutSnapshots = [(String, String?)]()

    init(host: Host, resources: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         runner: @escaping ([String], Bool) throws -> Void = runCommand,
         healthCheck: ((Configuration) throws -> Void)? = nil) {
        self.host = host; self.resources = resources; self.home = home
        self.runner = runner; self.healthCheck = healthCheck
    }

    private func checked(_ url: URL) throws {
        var path = url.standardizedFileURL
        while path.path.hasPrefix(home.path + "/") {
            if let type = try? files.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink { throw SetupError.invalid("安装目标不能是符号链接。") }
            path.deleteLastPathComponent()
        }
    }

    private func dictionary(_ url: URL) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        else { throw SetupError.invalid("桥接应用信息无效。") }
        return result
    }

    private func configuration(_ url: URL) throws -> Configuration {
        if files.fileExists(atPath: url.path) {
            let result = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            guard (1024...65535).contains(result.port),
                  result.token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            else { throw SetupError.invalid("现有桥接配置无效，未覆盖。") }
            if host == .figma && result.port != 47836 {
                throw SetupError.invalid("现有 Figma 桥接使用其他端口，公开版本固定使用 47836；未覆盖现有客户端。")
            }
            return result
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw SetupError.invalid("无法生成本机配对码。") }
        return Configuration(port: host == .figma ? 47836 : try availablePort(),
                             token: bytes.map { String(format: "%02x", $0) }.joined())
    }

    private func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SetupError.invalid("无法分配本机连接端口。") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0 else { throw SetupError.invalid("无法分配本机连接端口。") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        if !snapshots.contains(where: { $0.url == url }) {
            let old = try? Data(contentsOf: url)
            let mode = (try? files.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
            snapshots.append(FileSnapshot(url: url, data: old, permissions: mode))
        }
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func setShortcut(_ menu: String, value: String?) {
        let preferences = UserDefaults(suiteName: "com.adobe.xd")!
        var values = preferences.dictionary(forKey: "NSUserKeyEquivalents") ?? [:]
        if !shortcutSnapshots.contains(where: { $0.0 == menu }) { shortcutSnapshots.append((menu, values[menu] as? String)) }
        if let value { values[menu] = value } else { values.removeValue(forKey: menu) }
        preferences.set(values, forKey: "NSUserKeyEquivalents")
        preferences.synchronize()
    }

    private func configureShortcut(_ state: URL) throws {
        let menu = "在 PhotoCraft 中编辑", backup = state.appendingPathComponent("shortcut-backup.json")
        let preferences = UserDefaults(suiteName: "com.adobe.xd")!
        var record = (try? Data(contentsOf: backup)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let existing = record, (existing["menu"] as? String ?? "在 Compositor 中编辑") != menu {
            let oldMenu = existing["menu"] as? String ?? "在 Compositor 中编辑"
            if preferences.dictionary(forKey: "NSUserKeyEquivalents")?[oldMenu] as? String == "@p" {
                setShortcut(oldMenu, value: existing["previous"] as? String)
            }
            record = nil
        }
        if record == nil {
            let previous = preferences.dictionary(forKey: "NSUserKeyEquivalents")?[menu] as? String
            try write(JSONSerialization.data(withJSONObject: ["menu": menu, "previous": previous as Any? ?? NSNull()]), to: backup)
        }
        setShortcut(menu, value: "@p")
    }

    private func waitForBridge(_ config: Configuration) throws {
        for _ in 0..<8 {
            let semaphore = DispatchSemaphore(value: 0)
            let status = BridgeStatus()
            var request = URLRequest(url: URL(string: "http://localhost:\(config.port)/status")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 1
            request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200, let data,
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["jobs"] is [Any] {
                    status.setReady()
                }
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 2)
            task.cancel()
            if status.isReady() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw SetupError.invalid("桥接组件未能启动，已恢复原安装。")
    }

    func install() throws -> String {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: host.minimumOS, minorVersion: 0, patchVersion: 0))
        else { throw SetupError.invalid("此组件需要 macOS \(host.minimumOS) 或更高版本。") }
        let state = home.appendingPathComponent("Library/Application Support/" + host.stateName, isDirectory: true)
        let configFile = state.appendingPathComponent("bridge-config.json")
        let app = home.appendingPathComponent("Applications/" + host.appName, isDirectory: true)
        let agent = home.appendingPathComponent("Library/LaunchAgents/" + host.identity + ".plist")
        let plugin = host == .figma ? state.appendingPathComponent("plugin", isDirectory: true)
            : home.appendingPathComponent("Library/Application Support/Adobe/Adobe XD/develop/Compositor", isDirectory: true)
        for url in [state, configFile, app, agent, plugin] { try checked(url) }
        let config = try configuration(configFile)
        let payload = resources.appendingPathComponent(host.appName, isDirectory: true)
        let info = try dictionary(payload.appendingPathComponent("Contents/Info.plist"))
        guard info["CFBundleIdentifier"] as? String == host.identity else { throw SetupError.invalid("安装包中的桥接组件来源不符。") }
        if files.fileExists(atPath: app.path), try dictionary(app.appendingPathComponent("Contents/Info.plist"))["CFBundleIdentifier"] as? String != host.identity {
            throw SetupError.invalid("桥接应用目录已存在且来源不符，未改动。")
        }
        if files.fileExists(atPath: agent.path), try dictionary(agent)["Label"] as? String != host.identity {
            throw SetupError.invalid("启动项已存在且来源不符，未改动。")
        }
        let pluginSource = resources.appendingPathComponent("plugin", isDirectory: true)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: pluginSource.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard let pluginID = manifest?["id"] as? String, !pluginID.isEmpty else { throw SetupError.invalid("插件标识无效。") }
        if host == .figma {
            guard manifest?["enablePrivatePluginApi"] == nil,
                  (manifest?["networkAccess"] as? [String: Any])?["allowedDomains"] as? [String] == ["http://localhost:47836"]
            else { throw SetupError.invalid("Figma 插件不是公开配对版本。") }
        } else if pluginID != "CmptXd01" { throw SetupError.invalid("XD 插件标识无效。") }
        if files.fileExists(atPath: plugin.path) {
            let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: plugin.appendingPathComponent("manifest.json"))) as? [String: Any]
            guard existing?["id"] as? String == pluginID else { throw SetupError.invalid("插件目录已存在且来源不符，未改动。") }
        }
        try runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", payload.path], true)
        try files.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = app.deletingLastPathComponent().appendingPathComponent(".photocraft-" + UUID().uuidString + ".app")
        let previous = app.deletingLastPathComponent().appendingPathComponent(".photocraft-previous-" + UUID().uuidString + ".app")
        defer { try? files.removeItem(at: temporary) }
        try files.copyItem(at: payload, to: temporary)
        let domain = "gui/" + String(getuid())
        var replaced = false, movedPrevious = false
        do {
            try runner(["/bin/launchctl", "bootout", domain, agent.path], false)
            if files.fileExists(atPath: app.path) { try files.moveItem(at: app, to: previous); movedPrevious = true }
            try files.moveItem(at: temporary, to: app); replaced = true
            try files.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
            try files.createDirectory(at: plugin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if host == .figma { try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: plugin.path) }
            try write(JSONEncoder().encode(config), to: configFile)
            for name in host == .figma ? ["code.js", "manifest.json", "ui.html"] : ["main.js", "manifest.json"] {
                let contents = try Data(contentsOf: pluginSource.appendingPathComponent(name))
                guard contents.range(of: Data("__BRIDGE_TOKEN__".utf8)) == nil else { throw SetupError.invalid("安装包仍包含开发配置占位符。") }
                try write(contents, to: plugin.appendingPathComponent(name))
            }
            try files.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            let launch: [String: Any] = ["Label": host.identity,
                "ProgramArguments": [app.appendingPathComponent("Contents/MacOS/" + host.executable).path, configFile.path],
                "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Interactive", "ThrottleInterval": 10]
            try write(PropertyListSerialization.data(fromPropertyList: launch, format: .xml, options: 0), to: agent)
            if host == .xd { try configureShortcut(state) }
            try runner(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", app.path], true)
            try runner(["/bin/launchctl", "bootstrap", domain, agent.path], true)
            if let healthCheck { try healthCheck(config) } else { try waitForBridge(config) }
            if host == .xd {
                let obsolete = plugin.appendingPathComponent("bridge-config.json")
                try checked(obsolete)
                if files.fileExists(atPath: obsolete.path) { try files.removeItem(at: obsolete) }
            }
            if movedPrevious { try files.removeItem(at: previous) }
            return host == .figma ? config.token : "\(config.port):\(config.token)"
        } catch {
            try? runner(["/bin/launchctl", "bootout", domain, agent.path], false)
            for snapshot in snapshots.reversed() {
                if let data = snapshot.data {
                    try? data.write(to: snapshot.url, options: .atomic)
                    if let mode = snapshot.permissions { try? files.setAttributes([.posixPermissions: mode], ofItemAtPath: snapshot.url.path) }
                } else { try? files.removeItem(at: snapshot.url) }
            }
            for (menu, value) in shortcutSnapshots.reversed() { setShortcut(menu, value: value) }
            if replaced { try? files.removeItem(at: app) }
            if movedPrevious { try? files.moveItem(at: previous, to: app) }
            if files.fileExists(atPath: agent.path) { try? runner(["/bin/launchctl", "bootstrap", domain, agent.path], false) }
            throw error
        }
    }
}

private final class SetupDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "PhotoCraftHost") as? String,
                  let host = Host(rawValue: value), let resources = Bundle.main.resourceURL
            else { throw SetupError.invalid("安装包信息无效。") }
            let code = try Installer(host: host, resources: resources).install()
            let alert = NSAlert()
            alert.messageText = "安装完成"
            let field = NSTextField(string: code)
            field.frame = NSRect(x: 0, y: 0, width: 560, height: 24)
            field.isEditable = false; field.isSelectable = true
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            alert.accessoryView = field
            alert.addButton(withTitle: "复制配对码")
            alert.addButton(withTitle: "关闭")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "安装未完成"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = SetupDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
