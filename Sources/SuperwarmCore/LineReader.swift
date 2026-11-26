import Foundation

public enum LineReaderError: Error, CustomStringConvertible {
    case zstdUnavailable(path: String)
    case decompressionFailed(path: String, status: Int32)

    public var description: String {
        switch self {
        case .zstdUnavailable(let path):
            "Cannot read \(path): it is zstd-compressed and no `zstd` binary was found (brew install zstd)."
        case .decompressionFailed(let path, let status):
            "zstd exited with status \(status) while reading \(path)."
        }
    }
}

/// Streams newline-delimited records from plain or zstd-compressed files
/// without loading the whole file into memory.
public enum LineReader {
    static let zstdSearchPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]

    public static var zstdPath: String? {
        zstdSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Calls `body` once per line. Lines that do not contain any of `needles`
    /// are skipped before the caller sees them, which keeps JSON decoding off
    /// the vast majority of log lines.
    public static func forEachLine(
        in url: URL,
        containingAny needles: [Data] = [],
        _ body: (Data) throws -> Void
    ) throws {
        if url.pathExtension == "zst" {
            guard let zstd = zstdPath else { throw LineReaderError.zstdUnavailable(path: url.path) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: zstd)
            process.arguments = ["-dcq", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            try split(handle: pipe.fileHandleForReading, needles: needles, body)
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw LineReaderError.decompressionFailed(path: url.path, status: process.terminationStatus)
            }
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try split(handle: handle, needles: needles, body)
        }
    }

    static func split(handle: FileHandle, needles: [Data], _ body: (Data) throws -> Void) throws {
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                try emit(buffer[start..<newline], needles: needles, body)
                start = buffer.index(after: newline)
            }
            buffer = Data(buffer[start...])
        }
        if !buffer.isEmpty { try emit(buffer, needles: needles, body) }
    }

    /// Splits in-memory data; used by tests and small inputs.
    public static func forEachLine(in data: Data, containingAny needles: [Data] = [], _ body: (Data) throws -> Void) throws {
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            try emit(data[start..<newline], needles: needles, body)
            start = data.index(after: newline)
        }
        if start < data.endIndex { try emit(data[start...], needles: needles, body) }
    }

    private static func emit(_ line: Data, needles: [Data], _ body: (Data) throws -> Void) throws {
        guard !line.isEmpty else { return }
        if needles.isEmpty || needles.contains(where: { line.range(of: $0) != nil }) {
            try body(Data(line))
        }
    }
}
