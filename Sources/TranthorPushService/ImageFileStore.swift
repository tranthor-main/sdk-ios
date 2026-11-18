import Foundation

/// Reserve byte/file quotas before a download begins. Active sources are never reaped.
actor ImageFileStore {
    static let shared = ImageFileStore()
    private let root: URL
    private var reservations: [URL: Int] = [:]
    init(root: URL = FileManager.default.temporaryDirectory) { self.root = root }
    func begin(maximumBytes: Int) throws -> URL {
        guard reservations.count < 4 else { throw RichImageError.busy }
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var count = 0, size = reservations.values.reduce(0, +)
        for directory in directories where directory.lastPathComponent.hasPrefix("tranthor-image-") {
            guard UUID(uuidString: String(directory.lastPathComponent.dropFirst("tranthor-image-".count))) != nil,
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let sources = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            for file in sources {
                if reservations[file] != nil { count += 1; continue }
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if let date = values.contentModificationDate, date.timeIntervalSinceNow < -300 {
                    RichImageDownloader.remove(file, root: root); break
                }
                count += 1; size += values.fileSize ?? 0
            }
            if sources.isEmpty { try? manager.removeItem(at: directory) }
        }
        guard count < 32, size + maximumBytes <= 50 * 1024 * 1024 else { throw RichImageError.busy }
        let directory = root.appendingPathComponent("tranthor-image-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("image.part")
        do {
            try Data().write(to: file, options: .atomic)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = file; try excluded.setResourceValues(values)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            #endif
            reservations[file] = maximumBytes
            return file
        } catch { RichImageDownloader.remove(file, root: root); throw error }
    }
    func commit(_ part: URL, suffix: String) throws -> URL {
        let file = part.deletingLastPathComponent().appendingPathComponent("image." + suffix)
        try FileManager.default.moveItem(at: part, to: file)
        reservations.removeValue(forKey: part)
        return file
    }
    func abort(_ part: URL) { reservations.removeValue(forKey: part); RichImageDownloader.remove(part, root: root) }
}
