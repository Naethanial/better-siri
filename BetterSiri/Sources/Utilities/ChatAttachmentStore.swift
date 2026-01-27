import Foundation

enum ChatAttachmentStore {
    static func baseDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("BetterSiri", isDirectory: true)
            .appendingPathComponent("ChatAttachments", isDirectory: true)
    }

    static func sessionDirectory(sessionId: UUID) throws -> URL {
        let dir = baseDirectory()
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for attachment: ChatAttachment) -> URL {
        baseDirectory().appendingPathComponent(attachment.relativePath)
    }
}
