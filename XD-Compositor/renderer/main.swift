import Foundation

@main struct RendererCLI {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw ProjectError.invalid }
            let snapshot = try await ProjectStore.shared.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
            try await ImageExporter.shared.exportPNG(snapshot, to: URL(fileURLWithPath: CommandLine.arguments[2]))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
