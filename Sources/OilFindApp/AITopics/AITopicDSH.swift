import Foundation

/// DSH (DeepSeek-Harness) stores each session as an append-only zstd frame stream.
/// macOS ships no zstd decoder, so a bundled Node helper inflates frames; this file only
/// prepares inputs, runs the helper, and parses the projcache metadata beside each session.
struct DSHMetadata: Equatable {
    var title = ""
    var project = ""
    var modified: Double = 0
    var firstPrompt = ""
    var blank = false
    var automated = false
}

struct DSHSessionFile {
    let id: String
    let projectKey: String
    let directory: URL
    let transcript: URL
}

struct DSHDecodeResult {
    let plaintext: Data
    let endOffset: Int64
}

enum DSHRuntime {
    private final class Box {
        var data = Data()
        var error = Data()
    }
    private static let timeout: TimeInterval = 60

    static func node(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     executable: (URL) -> Bool = defaultExecutable) -> URL? {
        var candidates: [URL] = []
        if let override = environment["OILFIND_DSH_NODE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for directory in pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            candidates.append(URL(fileURLWithPath: directory).appendingPathComponent("node"))
        }
        candidates.append(home.appendingPathComponent(".local/bin/node"))
        candidates.append(home.appendingPathComponent(".volta/bin/node"))
        for (root, suffix) in [(".nvm/versions/node", "bin/node"), (".local/share/fnm/node-versions", "installation/bin/node")] {
            let directory = home.appendingPathComponent(root)
            if let versions = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    candidates.append(version.appendingPathComponent(suffix))
                }
            }
        }
        var seen = Set<String>()
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted, executable(url) else { continue }
            return url
        }
        return nil
    }

    static func script() -> URL? {
        // SwiftPM's generated accessor fatals when the bundle is missing, so resolve it by hand.
        let bases = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle(for: Token.self).bundleURL, Bundle(for: Token.self).bundleURL.deletingLastPathComponent(),
                     Bundle(for: Token.self).resourceURL].compactMap { $0 }
        let relatives = ["OilFind_OilFindApp.bundle/Contents/Resources/Resources/dsh-decode.js",
                         "OilFind_OilFindApp.bundle/Resources/Resources/dsh-decode.js",
                         "OilFind_OilFindApp.bundle/Contents/Resources/dsh-decode.js",
                         "OilFind_OilFindApp.bundle/Resources/dsh-decode.js",
                         "Resources/dsh-decode.js", "dsh-decode.js"]
        for base in bases {
            for relative in relatives {
                let url = base.appendingPathComponent(relative)
                if FileManager.default.isReadableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    static func decode(path: String, start: Int64, node: URL, script: URL) throws -> DSHDecodeResult {
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path, path, String(start)]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let box = Box(), done = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "com.oiloil.find.dsh.decode")
        queue.async {
            box.data = stdout.fileHandleForReading.readDataToEndOfFile()
            box.error = stderr.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do { try process.run() } catch { throw error }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            throw AITopicError.database("DSH decoder timed out")
        }
        process.waitUntilExit()
        var output = Data(), error = Data()
        queue.sync { output = box.data; error = box.error }
        guard process.terminationStatus == 0 else {
            let message = String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AITopicError.database(message.isEmpty ? "DSH decoder failed" : message)
        }
        let text = String(data: error, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("CURSOR ") }) else {
            throw AITopicError.database("DSH decoder returned no cursor")
        }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let end = Int64(fields[1]) else { throw AITopicError.database("DSH decoder cursor is invalid") }
        return DSHDecodeResult(plaintext: output, endOffset: end)
    }

    private final class Token {}

    private static func defaultExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

enum DSHSessionStore {
    static func sessionFile(in directory: URL) -> URL? {
        let names = ["session.v4.jsonl.zstd", "session.v3.jsonl.zstd", "session.v2.jsonl.zstd", "session.jsonl.zstd"]
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.isRegularFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// All live sessions, newest first. Version preference is per session directory.
    static func sessions(root: URL) -> [DSHSessionFile] {
        let files = FileManager.default
        guard let projects = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [DSHSessionFile] = []
        for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let children = try? files.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let transcript = sessionFile(in: child) else { continue }
                result.append(DSHSessionFile(id: child.lastPathComponent, projectKey: project.lastPathComponent, directory: child, transcript: transcript))
            }
        }
        return result.sorted { modified($0.transcript) > modified($1.transcript) }
    }

    static func metadata(for session: DSHSessionFile, cache: URL?) -> DSHMetadata {
        var metadata = DSHMetadata()
        metadata.modified = modified(session.transcript)
        if let cache, let data = try? Data(contentsOf: cache),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = (object["record"] as? [String: Any])?["rows"] as? [String: Any] {
            metadata.title = string(value(rows["title"]))
            let input = value(rows["titleInput"]) as? [String: Any]
            metadata.firstPrompt = string((input?["first"] as? [String: Any])?["text"])
            let list = value(rows["sessionListMetadata"]) as? [String: Any]
            metadata.blank = list?["blank"] as? Bool ?? false
            if let milliseconds = number(list?["lastPromptAt"]) { metadata.modified = milliseconds > 100_000_000_000 ? milliseconds / 1000 : milliseconds }
            metadata.project = string(value(rows["workingDirectory"]))
            let subagent = value(rows["subagent"]) as? [String: Any]
            metadata.automated = subagent?["identity"] != nil
            if metadata.title.isEmpty { metadata.title = String(metadata.firstPrompt.prefix(120)).replacingOccurrences(of: "\n", with: " ") }
        }
        return metadata
    }

    static func cacheFile(sessionsRoot: URL, id: String) -> URL? {
        // ~/.dsh/sessions -> ~/.dsh/storages/session_projcache/sessions/<id>.json
        var dsh = sessionsRoot.deletingLastPathComponent()
        while dsh.path != "/" && dsh.lastPathComponent != ".dsh" { dsh.deleteLastPathComponent() }
        guard dsh.lastPathComponent == ".dsh" else { return nil }
        return dsh.appendingPathComponent("storages/session_projcache/sessions").appendingPathComponent(id + ".json")
    }

    private static func value(_ row: Any?) -> Any? {
        guard let dictionary = row as? [String: Any] else { return row }
        return dictionary["val"] ?? row
    }
    private static func string(_ value: Any?) -> String { if let text = value as? String { return text }; return "" }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
    private static func modified(_ url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
}

private extension FileManager {
    func isRegularFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
