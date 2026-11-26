import Foundation

/// Where one tool keeps its logs on disk.
public struct LogSource: Sendable {
    public var provider: Provider
    public var roots: [URL]

    public init(provider: Provider, roots: [URL]) {
        self.provider = provider
        self.roots = roots
    }

    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> [LogSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeRoots: [URL]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            claudeRoots = configured.split(separator: ",").map {
                URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).appendingPathComponent("projects")
            }
        } else {
            claudeRoots = [
                home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects"),
            ]
        }
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        return [
            LogSource(provider: .claudeCode, roots: claudeRoots),
            LogSource(provider: .codex, roots: [
                codexHome.appendingPathComponent("sessions"),
                codexHome.appendingPathComponent("archived_sessions"),
            ]),
        ]
    }
}

/// Parsed records for one log file, reused while the file is unchanged.
public struct CachedFile: Codable, Sendable {
    public var size: Int64
    public var modified: Date
    public var records: [UsageRecord]
}

public struct ScanCache: Codable, Sendable {
    public static let currentVersion = 1
    public var version = ScanCache.currentVersion
    public var files: [String: CachedFile] = [:]

    public init() {}

    public static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("usage-cache.plist")
    }

    public static func load(from url: URL = defaultURL) -> ScanCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(ScanCache.self, from: data),
              cache.version == currentVersion
        else { return ScanCache() }
        return cache
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct ScanResult: Sendable {
    public var records: [UsageRecord]
    public var filesFound: Int
    public var filesParsed: Int
    public var issues: [String]
}

public struct UsageScanner: Sendable {
    public var sources: [LogSource]

    public init(sources: [LogSource] = LogSource.defaults()) {
        self.sources = sources
    }

    struct FileTask {
        let provider: Provider
        let url: URL
        let size: Int64
        let modified: Date
    }

    func discover() -> [FileTask] {
        let fm = FileManager.default
        var tasks: [FileTask] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for source in sources {
            for root in source.roots where fm.fileExists(atPath: root.path) {
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
                for case let url as URL in enumerator {
                    let name = url.lastPathComponent
                    guard name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { continue }
                    guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                    tasks.append(FileTask(
                        provider: source.provider,
                        url: url,
                        size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate ?? .distantPast
                    ))
                }
            }
        }
        return tasks
    }

    /// Scans all sources and re-parses only files whose size or mtime changed since `cache`.
    public func scan(cache: inout ScanCache) -> ScanResult {
        let tasks = discover()
        let stale = tasks.filter { task in
            guard let cached = cache.files[task.url.path] else { return true }
            return cached.size != task.size || cached.modified != task.modified
        }

        let lock = NSLock()
        nonisolated(unsafe) var parsed: [String: CachedFile] = [:]
        nonisolated(unsafe) var issues: [String] = []
        DispatchQueue.concurrentPerform(iterations: stale.count) { index in
            let task = stale[index]
            do {
                let records: [UsageRecord] = switch task.provider {
                case .claudeCode: try ClaudeCodeParser().parse(url: task.url)
                case .codex: try CodexParser().parse(url: task.url)
                }
                let file = CachedFile(size: task.size, modified: task.modified, records: records)
                lock.withLock { parsed[task.url.path] = file }
            } catch {
                lock.withLock { issues.append("\(error)") }
            }
        }

        var files: [String: CachedFile] = [:]
        for task in tasks {
            if let fresh = parsed[task.url.path] {
                files[task.url.path] = fresh
            } else if let cached = cache.files[task.url.path] {
                files[task.url.path] = cached
            }
        }
        cache.files = files

        return ScanResult(
            records: Self.deduplicate(files.values.flatMap(\.records)),
            filesFound: tasks.count,
            filesParsed: parsed.count,
            issues: Self.summarize(issues)
        )
    }

    /// The same response can be logged in several files (e.g. a resumed Claude
    /// Code session copies its history). Keep one record per id.
    public static func deduplicate(_ records: [UsageRecord]) -> [UsageRecord] {
        var byID: [String: UsageRecord] = [:]
        byID.reserveCapacity(records.count)
        for record in records {
            if var existing = byID[record.id] {
                existing.tokens = existing.tokens.fieldwiseMax(record.tokens)
                existing.timestamp = min(existing.timestamp, record.timestamp)
                byID[record.id] = existing
            } else {
                byID[record.id] = record
            }
        }
        return byID.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Collapses repeated errors (e.g. a missing zstd binary for every Codex file).
    static func summarize(_ issues: [String]) -> [String] {
        let zstdMissing = issues.filter { $0.contains("no `zstd` binary") }
        var result = issues.filter { !$0.contains("no `zstd` binary") }.sorted()
        if !zstdMissing.isEmpty {
            result.insert("\(zstdMissing.count) compressed Codex logs skipped: install zstd (brew install zstd) to include them.", at: 0)
        }
        return result
    }
}
