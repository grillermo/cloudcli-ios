import Foundation

/// Holds recordings that were not transcribed yet. `root` must live in Application
/// Support (not tmp or Caches), or iOS may purge audio that was never transcribed.
public struct PendingRecordingStore: Sendable {
    /// Readable after the first unlock, so a recording survives a locked phone.
    public static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func newFile() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection])
        try? FileManager.default.setAttributes([.protectionKey: Self.protection], ofItemAtPath: root.path)
        return root.appending(path: "\(UUID().uuidString).m4a")
    }

    /// Oldest first.
    public func all() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "m4a" }.sorted { created($0) < created($1) }
    }

    public func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
