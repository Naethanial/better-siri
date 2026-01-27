import Foundation
import UniformTypeIdentifiers

struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case image
        case pdf
        case model
        case other
    }

    let id: UUID
    let kind: Kind
    let filename: String
    /// Path relative to the attachments base directory.
    let relativePath: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        filename: String,
        relativePath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.relativePath = relativePath
        self.createdAt = createdAt
    }

    static func inferKind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .threeDContent) { return .model }
        }

        // Heuristic fallback for common CAD/mesh formats that may not be tagged as threeDContent.
        switch ext {
        case "stl", "obj", "step", "stp", "iges", "igs", "x_t", "x_b", "sldprt", "sldasm", "3mf", "glb", "gltf":
            return .model
        default:
            return .other
        }
    }
}
