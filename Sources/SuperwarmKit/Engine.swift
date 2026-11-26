import Foundation

/// Settings passed to the engine on each run.
public struct EngineOptions: Sendable, Equatable {
    public var gramsCO2PerKWh: Double
    public var pue: Double
    public var commuteMilesOneWay: Double
    /// Use the engine's synthetic demo year instead of real logs.
    public var demo: Bool

    public init(gramsCO2PerKWh: Double = 373, pue: Double = 1.15, commuteMilesOneWay: Double = 11.7, demo: Bool = false) {
        self.gramsCO2PerKWh = gramsCO2PerKWh
        self.pue = pue
        self.commuteMilesOneWay = commuteMilesOneWay
        self.demo = demo
    }

    var arguments: [String] {
        var args = [
            "snapshot",
            "--grid", String(gramsCO2PerKWh),
            "--pue", String(pue),
            "--commute", String(commuteMilesOneWay),
        ]
        if demo { args.append("--demo") }
        return args
    }
}

public enum EngineError: Error, CustomStringConvertible, Equatable {
    case notFound
    case failed(status: Int32, message: String)
    case incompatible(schemaVersion: Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notFound:
            "Superwarm's engine is missing. Reinstall Superwarm."
        case .failed(let status, let message):
            "The engine failed (exit \(status)): \(message)"
        case .incompatible(let version):
            "The engine's data format (v\(version)) doesn't match this app. Update Superwarm."
        case .unreadable(let detail):
            "Couldn't read the engine's output: \(detail)"
        }
    }
}

/// Runs the Rust `superwarm` engine and decodes its snapshot.
public struct Engine: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Finds the engine:
    /// 1. `$SUPERWARM_ENGINE`
    /// 2. `Superwarm.app/Contents/Helpers/superwarm` (release builds)
    /// 3. `engine/target/{release,debug}/superwarm` in a source checkout (`swift run`)
    /// 4. `superwarm` on the PATH
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Engine? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = environment["SUPERWARM_ENGINE"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/superwarm"))
        var dir = bundle.executableURL?.deletingLastPathComponent()
        while let current = dir, current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent("engine/Cargo.toml").path) {
                candidates.append(current.appendingPathComponent("engine/target/release/superwarm"))
                candidates.append(current.appendingPathComponent("engine/target/debug/superwarm"))
                break
            }
            dir = current.deletingLastPathComponent()
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(entry)).appendingPathComponent("superwarm"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }.map(Engine.init)
    }

    /// Runs `superwarm snapshot` synchronously; call it off the main thread.
    public func snapshot(_ options: EngineOptions) throws -> Snapshot {
        let process = Process()
        process.executableURL = executable
        process.arguments = options.arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read before waiting so a large snapshot can't fill the pipe and deadlock.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.failed(status: process.terminationStatus, message: message)
        }
        return try Self.decode(output)
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        struct Version: Decodable { var schemaVersion: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else {
            throw EngineError.unreadable("not a snapshot")
        }
        guard version.schemaVersion == Snapshot.supportedSchemaVersion else {
            throw EngineError.incompatible(schemaVersion: version.schemaVersion)
        }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw EngineError.unreadable("\(error)")
        }
    }
}
