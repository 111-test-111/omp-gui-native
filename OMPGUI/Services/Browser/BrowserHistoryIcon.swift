import AppKit
import ImageIO

enum BrowserHistoryIconCodec {
    @MainActor static func encode(_ image: NSImage) -> BrowserHistoryIcon? {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              (1...64).contains(bitmap.pixelsWide), (1...64).contains(bitmap.pixelsHigh),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= BrowserHistoryIcon.maximumBytes else { return nil }
        return .init(png: png, isTemplate: image.isTemplate)
    }

    @MainActor static func decode(_ icon: BrowserHistoryIcon) -> NSImage? {
        guard icon.png.count <= BrowserHistoryIcon.maximumBytes,
              let source = CGImageSourceCreateWithData(icon.png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...64).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...64).contains(height),
              let image = NSImage(data: icon.png) else { return nil }
        image.isTemplate = icon.isTemplate
        return image
    }

    @MainActor static func downloaded(_ data: Data) -> NSImage? {
        guard data.count <= BrowserHistoryIconDownload.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: thumbnail))
        return AdaptiveIconImage.prepared(image)
    }
}

/// Old records can acquire a site's own icon without opening a hidden browser.
/// Reuse the tab cache's request coalescing, expiry and 64-request/128-image bounds.
@MainActor
enum BrowserHistoryIconLoader {
    static func source(for address: String) -> URL? {
        guard let url = BrowserAddress.resolve(address), url.scheme != "about",
              var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = "/favicon.ico"; origin.query = nil; origin.fragment = nil
        return origin.url
    }

    static func image(for address: String) async -> NSImage? {
        guard let source = source(for: address), !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            BrowserFaviconCache.shared.load(.init(profileID: BrowserProfileConfiguration.activeProfile.id, url: source, isDark: false), fetch: { url, _, complete in
                BrowserHistoryIconDownload.start(url) { data in
                    Task { @MainActor in complete(data.flatMap(BrowserHistoryIconCodec.downloaded)) }
                }
            }) { continuation.resume(returning: $0) }
        }
    }
}

/// Ephemeral, credential-free and byte-bounded. The serial delegate queue owns
/// the mutable request state, and invalidation releases the session/delegate cycle.
private final class BrowserHistoryIconDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 1_048_576
    private var data = Data()
    private let completion: @Sendable (Data?) -> Void

    private init(completion: @escaping @Sendable (Data?) -> Void) { self.completion = completion }

    static func start(_ url: URL, completion: @escaping @Sendable (Data?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let delegate = BrowserHistoryIconDownload(completion: completion)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              response.expectedContentLength <= Int64(Self.maximumBytes) else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count + bytes.count <= Self.maximumBytes else { dataTask.cancel(); return }
        data.append(bytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let target = BrowserAddress.resolve(url.absoluteString),
              target.scheme != "about" else { completionHandler(nil); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion(error == nil && !data.isEmpty ? data : nil)
        session.finishTasksAndInvalidate()
    }
}
