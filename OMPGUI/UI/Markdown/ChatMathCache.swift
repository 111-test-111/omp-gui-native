import Foundation
import CryptoKit
import CoreGraphics

/// Disposable image data only: no source text, credentials or conversation IDs.
/// The namespace changes whenever MathJax/configuration or image geometry changes.
actor ChatMathCache {
    private let root: URL
    private static let fileLimit = 16 * 1024 * 1024
    private static let byteLimit = 128 * 1024 * 1024
    private static let countLimit = 4096

    init(root: URL) { self.root = root.appendingPathComponent("mathjax-4.1.3-images-v2", isDirectory: true) }
    private nonisolated func file(_ key: String) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    // Atomic files allow reads to bypass a background write/prune backlog.
    @concurrent nonisolated func load(_ keys: [String]) async -> [String: ChatMathRenderer.Image] {
        var hits: [String: ChatMathRenderer.Image] = [:]
        for key in keys {
            let url = file(key)
            guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  bytes > 0, bytes <= Self.fileLimit else { continue }
            if let data = try? Data(contentsOf: url), let image = try? ChatMathRenderer.Image(archive: data) {
                hits[key] = image
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else { try? FileManager.default.removeItem(at: url) }
        }
        return hits
    }

    func store(_ images: [(String, ChatMathRenderer.Image)]) {
        guard !images.isEmpty else { return }
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return }
        for (key, image) in images {
            guard let data = try? image.archive(), data.count <= Self.fileLimit else { continue }
            let url = file(key)
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        // Actor-isolated I/O never holds up native text/layout. Evict oldest use
        // on writes, bounding both many tiny formulas and a few large images.
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let files = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = files.reduce(0) { $0 + $1.1 }, count = files.count
        for (url, size, _) in files {
            guard bytes > Self.byteLimit || count > Self.countLimit else { break }
            try? fm.removeItem(at: url); bytes -= size; count -= 1
        }
    }
}

extension ChatMathRenderer.Image {
    private struct Archive: Codable {
        let width: Int, height: Int
        let scale: CGFloat, descent: CGFloat, axis: CGFloat
        let mask: Data
        let foreground: Data?
        let colors: Data?
    }
    func archive() throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(Archive(width: mask.width, height: mask.height, scale: scale, descent: descent, axis: axis,
            mask: mask.dataProvider!.data! as Data,
            foreground: foregroundMask === mask ? nil : foregroundMask.dataProvider!.data! as Data,
            colors: explicitColors?.dataProvider?.data as Data?))
    }
    convenience init(archive data: Data) throws {
        let value = try PropertyListDecoder().decode(Archive.self, from: data)
        guard value.width > 0, value.height > 0, value.width <= 16_384, value.height <= 16_384,
              value.width * value.height <= 16_000_000, value.scale.isFinite, (2...4).contains(value.scale),
              value.descent.isFinite, value.axis.isFinite else { throw ChatMathRenderer.Failure(message: "Invalid cached formula") }
        let count = value.width * value.height
        func mask(_ bytes: Data) throws -> CGImage {
            guard bytes.count == count, let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(maskWidth: value.width, height: value.height, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: value.width, provider: provider, decode: [1, 0], shouldInterpolate: true) else {
                throw ChatMathRenderer.Failure(message: "Invalid cached formula")
            }
            return image
        }
        let full = try mask(value.mask)
        let foreground = try value.foreground.map(mask) ?? full
        var colors: CGImage?
        if let bytes = value.colors {
            guard bytes.count == count * 4, let provider = CGDataProvider(data: bytes as CFData) else {
                throw ChatMathRenderer.Failure(message: "Invalid cached formula")
            }
            colors = CGImage(width: value.width, height: value.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: value.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            guard colors != nil else { throw ChatMathRenderer.Failure(message: "Invalid cached formula") }
        }
        self.init(mask: full, foregroundMask: foreground, explicitColors: colors, scale: value.scale, descent: value.descent, axis: value.axis)
    }
}
