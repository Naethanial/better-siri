import Foundation

enum AppLogLevel: String {
    case info = "INFO"
    case debug = "DEBUG"
    case error = "ERROR"
}

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.bettersiri.applog")
    private let fileURL: URL
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let logDir = (baseDir ?? fileManager.temporaryDirectory)
            .appendingPathComponent("BetterSiri", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)

        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)

        fileURL = logDir.appendingPathComponent("bettersiri.log")
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func log(_ message: String, level: AppLogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"

        queue.async { [fileURL] in
            let fileManager = FileManager.default
            guard let data = line.data(using: .utf8) else { return }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }

            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                return
            }
        }
    }

    func export(to destinationURL: URL) throws {
        try queue.sync {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: fileURL, to: destinationURL)
        }
    }

    func currentLogURL() -> URL {
        fileURL
    }
}
