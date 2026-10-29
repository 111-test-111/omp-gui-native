import Foundation

enum OMPHistoryAttachments {
    /// OMP owns the persisted image payload. Restore missing GUI copies without
    /// depending on paths that may have been moved after the original send.
    @concurrent
    static func restore(images: [OMPHistoryImage], keeping attachments: [Attachment]) async throws -> [Attachment] {
        let existingImages = attachments.filter(\.isImage)
        guard images.count <= 64 else { throw OMPHistoryError.invalidHistory }
        var result = attachments.filter { !$0.isImage }
        var written: [URL] = []
        do {
            var total = 0
            for (index, image) in images.enumerated() {
                guard image.data.utf8.count <= 32 * 1_024 * 1_024, let data = Data(base64Encoded: image.data), !data.isEmpty else {
                    throw OMPHistoryError.invalidHistory
                }
                total += data.count
                guard total <= 64 * 1_024 * 1_024 else { throw OMPHistoryError.invalidHistory }
                let ext: String
                switch image.mimeType {
                case "image/png": ext = "png"
                case "image/jpeg": ext = "jpg"
                case "image/gif": ext = "gif"
                case "image/webp": ext = "webp"
                default: ext = "img"
                }
                let id = UUID()
                let url = Storage.attachmentsDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
                try data.write(to: url, options: .atomic)
                written.append(url)
                let previous = existingImages.indices.contains(index) ? existingImages[index] : nil
                result.append(Attachment(id: previous?.id ?? id, name: previous?.name ?? "image-\(index + 1).\(ext)", path: url.path, mimeType: image.mimeType))
            }
            return result
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
