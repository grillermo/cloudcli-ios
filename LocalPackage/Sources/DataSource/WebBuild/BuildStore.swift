import CryptoKit
import Foundation

public actor BuildStore {
    public typealias Fetch = @Sendable (String) async throws -> Data

    public enum Failure: Error, Equatable {
        case hashMismatch(String)
        case unsafePath(String)
        case notReady(String)
        case invalidBuildId(String)
    }

    public struct Pointer: Codable, Equatable, Sendable {
        public var current: String?
        public var previous: String?
    }

    private static let manifestName = ".manifest.json"
    private let root: URL
    private let fetch: Fetch
    private let files = FileManager.default
    private var inFlight: [String: Task<Void, any Error>] = [:]

    public init(root: URL, fetch: @escaping Fetch) {
        self.root = root
        self.fetch = fetch
        Self.removePartials(in: root.appending(path: "builds", directoryHint: .isDirectory))
    }

    /// Partial downloads left by a previous launch. Only called from init, before any prepare runs.
    private static func removePartials(in builds: URL) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: builds.path)) ?? [] where name.hasSuffix(".partial") {
            try? manager.removeItem(at: builds.appending(path: name))
        }
    }

    private static func isValid(id: String) -> Bool {
        guard id != ".", id != "..", !id.isEmpty, !id.hasSuffix(".partial") else { return false }
        return id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func validate(_ id: String) throws {
        guard isValid(id: id) else { throw Failure.invalidBuildId(id) }
    }

    private var builds: URL { root.appending(path: "builds", directoryHint: .isDirectory) }
    private var pointerFile: URL { root.appending(path: "current.json") }
    private func folder(_ id: String) -> URL { builds.appending(path: id, directoryHint: .isDirectory) }

    public func pointer() -> Pointer {
        guard let data = try? Data(contentsOf: pointerFile),
              let value = try? JSONDecoder().decode(Pointer.self, from: data) else {
            return Pointer()
        }
        return value
    }

    /// A build's manifest is written last, so its presence means the build is complete.
    public func isReady(_ id: String) -> Bool {
        files.fileExists(atPath: folder(id).appending(path: Self.manifestName).path)
    }

    public func currentDirectory() -> URL? {
        guard let id = pointer().current, isReady(id) else { return nil }
        return folder(id)
    }

    public func prepare(_ manifest: BuildManifest) async throws {
        try Self.validate(manifest.buildId)
        guard !isReady(manifest.buildId) else { return }
        if let running = inFlight[manifest.buildId] {
            try await running.value
            return
        }
        let task = Task { try await self.download(manifest) }
        inFlight[manifest.buildId] = task
        defer { inFlight[manifest.buildId] = nil }
        try await task.value
    }

    private func download(_ manifest: BuildManifest) async throws {
        let partial = builds.appending(path: "\(manifest.buildId).partial", directoryHint: .isDirectory)
        try? files.removeItem(at: partial)
        try files.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            let known = currentFiles()
            for file in manifest.files {
                guard Self.isSafe(file.path) else { throw Failure.unsafePath(file.path) }
                let destination = partial.appending(path: file.path)
                try files.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data: Data
                if let existing = known[file.path], existing.sha256 == file.sha256 {
                    data = try Data(contentsOf: existing.url)
                } else {
                    data = try await fetch(file.path)
                }
                guard Self.sha256(data) == file.sha256 else { throw Failure.hashMismatch(file.path) }
                try data.write(to: destination)
            }
            try JSONEncoder().encode(manifest).write(to: partial.appending(path: Self.manifestName))
            if isReady(manifest.buildId) {
                // Never replace a build that is already complete: it may be the current one.
                try? files.removeItem(at: partial)
                return
            }
            try? files.removeItem(at: folder(manifest.buildId))
            try files.moveItem(at: partial, to: folder(manifest.buildId))
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
    }

    public func activate(_ id: String) throws {
        try Self.validate(id)
        guard isReady(id) else { throw Failure.notReady(id) }
        let old = pointer()
        try write(Pointer(current: id, previous: old.current == id ? old.previous : old.current))
        prune()
    }

    /// Returns the build now current, or nil when there is nothing to return to.
    public func rollback() throws -> String? {
        let old = pointer()
        guard let previous = old.previous else { return nil }
        try Self.validate(previous)
        guard isReady(previous) else { return nil }
        try write(Pointer(current: previous, previous: nil))
        return previous
    }

    private func write(_ value: Pointer) throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: pointerFile, options: .atomic)
    }

    private func prune() {
        let value = pointer()
        let keep = Set([value.current, value.previous].compactMap(\.self))
        for name in (try? files.contentsOfDirectory(atPath: builds.path)) ?? [] where !keep.contains(name) && !name.hasSuffix(".partial") {
            try? files.removeItem(at: builds.appending(path: name))
        }
    }

    private func currentFiles() -> [String: (sha256: String, url: URL)] {
        guard let directory = currentDirectory(),
              let data = try? Data(contentsOf: directory.appending(path: Self.manifestName)),
              let manifest = try? JSONDecoder().decode(BuildManifest.self, from: data) else {
            return [:]
        }
        var result: [String: (sha256: String, url: URL)] = [:]
        for file in manifest.files {
            result[file.path] = (file.sha256, directory.appending(path: file.path))
        }
        return result
    }

    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.utf8.contains(0) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
