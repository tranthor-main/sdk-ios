import Foundation

/// Why an image was not downloaded, or why a ``RichImageConfiguration`` was refused.
public enum RichImageError: Error, Sendable, Equatable {
    /// `RichImageConfiguration` was given a host entry that is not a bare host name, or a limit out of range.
    case invalidConfiguration
    /// The URL is not HTTPS on an allowed host.
    case disallowedURL
    /// The server answered with something other than a successful image response, or redirected.
    case invalidResponse
    /// The image is larger than the configured maximum.
    case oversizedImage
    /// The response is not a supported image.
    case invalidImage
    /// The download ended before the whole image arrived.
    case truncatedImage
    /// Too many images are being downloaded or stored at once.
    case busy
}

/// Limits for downloading a push notification's image. Only HTTPS URLs on the listed hosts are fetched.
public struct RichImageConfiguration: Sendable {
    /// Exact host names (no scheme, port or path), lowercased. A URL on any other host is refused.
    public let allowedHosts: Set<String>
    /// The largest response body accepted, in bytes.
    public let maximumBytes: Int
    /// The request and total download timeout, in seconds.
    public let timeoutSeconds: TimeInterval
    /// - Parameters:
    ///   - allowedHosts: Host names such as `images.example.com`.
    ///   - maximumBytes: 1 to 10 MiB. Default 5 MiB.
    ///   - timeoutSeconds: 1 to 20. Default 10.
    /// - Throws: When a host entry is not a bare host name or a limit is out of range.
    public init(allowedHosts: Set<String>, maximumBytes: Int = 5 * 1024 * 1024, timeoutSeconds: TimeInterval = 10) throws {
        guard (1...10 * 1024 * 1024).contains(maximumBytes), timeoutSeconds.isFinite, (1...20).contains(timeoutSeconds),
              allowedHosts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 253 &&
                  $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) })
        else { throw RichImageError.invalidConfiguration }
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.maximumBytes = maximumBytes; self.timeoutSeconds = timeoutSeconds
    }
    private init(noHosts: ()) { allowedHosts = []; maximumBytes = 5 * 1024 * 1024; timeoutSeconds = 10 }
    /// Allows no host, so every image is refused.
    static let noImages = RichImageConfiguration(noHosts: ())
    func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) && url.fragment == nil &&
        url.host.map { allowedHosts.contains($0.lowercased()) } == true
    }
}
