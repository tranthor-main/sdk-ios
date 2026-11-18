import Foundation
import ImageIO

/// Downloads a notification image to a temporary file. Independent of analytics, write keys, device tokens and
/// the app's event queue. URLs and query strings are never logged.
package actor RichImageDownloader {
    private let configuration: RichImageConfiguration
    private let session: URLSession
    private let transfers = ImageTransfers()
    package init(configuration: RichImageConfiguration) {
        let transport = URLSessionConfiguration.ephemeral
        transport.timeoutIntervalForRequest = configuration.timeoutSeconds
        transport.timeoutIntervalForResource = configuration.timeoutSeconds
        transport.httpCookieStorage = nil; transport.urlCredentialStorage = nil; transport.urlCache = nil
        self.init(configuration: configuration, transport: transport)
    }
    /// Tests pass a configuration with a `URLProtocol`, so no CDN is contacted.
    init(configuration: RichImageConfiguration, transport: URLSessionConfiguration) {
        self.configuration = configuration
        session = URLSession(configuration: transport, delegate: transfers, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    package func shutdown() { session.invalidateAndCancel() }

    /// Copies app-supplied image data into the same quota-checked, validated file as a download, for a local preview.
    package static func prepareAttachment(_ data: Data, mime: String) async throws -> URL {
        guard data.count <= 5 * 1024 * 1024 else { throw RichImageError.oversizedImage }
        let suffix = try validate(data, mime: mime)
        let part = try await ImageFileStore.shared.begin(maximumBytes: data.count)
        do {
            try data.write(to: part) // Preserve the reserved file's protection/backup attributes.
            try Task.checkCancellation()
            return try await ImageFileStore.shared.commit(part, suffix: suffix)
        } catch { await ImageFileStore.shared.abort(part); throw error }
    }

    /// Streams the image into a file chunk by chunk, never holding the whole image in memory, and returns the
    /// validated file. The caller removes it with ``remove(_:)``.
    package func download(_ url: URL) async throws -> URL {
        guard configuration.accepts(url) else { throw RichImageError.disallowedURL }
        try Task.checkCancellation()
        let part = try await ImageFileStore.shared.begin(maximumBytes: configuration.maximumBytes)
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = configuration.timeoutSeconds
            request.setValue("image/png, image/jpeg, image/gif", forHTTPHeaderField: "Accept")
            let mime = try await transfers.download(request, using: session, into: part, configuration: configuration)
            let suffix = try Self.validate(file: part, mime: mime)
            try Task.checkCancellation()
            return try await ImageFileStore.shared.commit(part, suffix: suffix)
        } catch { await ImageFileStore.shared.abort(part); throw error }
    }
    static func validate(_ data: Data, mime: String) throws -> String {
        try validateTrailer(Data(data.suffix(12)), mime: mime)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw RichImageError.invalidImage }
        return try validate(source: source, mime: mime)
    }
    static func validate(file: URL, mime: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 12 ? size - 12 : 0)
        try validateTrailer(handle.readToEnd() ?? Data(), mime: mime)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw RichImageError.invalidImage }
        return try validate(source: source, mime: mime)
    }
    private static func validateTrailer(_ tail: Data, mime: String) throws {
        let valid: Bool
        switch mime {
        case "image/png": valid = tail == Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
        case "image/jpeg": valid = tail.suffix(2) == Data([255, 217])
        case "image/gif": valid = tail.last == 59
        default: throw RichImageError.invalidImage
        }
        guard valid else { throw RichImageError.truncatedImage }
    }
    private static func validate(source: CGImageSource, mime: String) throws -> String {
        guard CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 16_000_000 else { throw RichImageError.invalidImage }
        switch (type, mime) {
        case ("public.png", "image/png"): return "png"
        case ("public.jpeg", "image/jpeg"): return "jpg"
        case ("com.compuserve.gif", "image/gif"): return "gif"
        default: throw RichImageError.invalidImage
        }
    }
    package nonisolated static func remove(_ file: URL) {
        remove(file, root: FileManager.default.temporaryDirectory)
    }
    nonisolated static func remove(_ file: URL, root: URL) {
        let directory = file.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("tranthor-image-"),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst("tranthor-image-".count))) != nil,
              directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
