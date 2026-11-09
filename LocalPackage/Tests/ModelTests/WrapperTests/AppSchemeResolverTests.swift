import Foundation
import Testing

@testable import DataSource

struct AppSchemeResolverTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        try Data("html".utf8).write(to: root.appending(path: "index.html"))
        try Data("js".utf8).write(to: root.appending(path: "assets/app.js"))
        return root
    }

    private func resolve(_ url: String, _ root: URL) throws -> AppSchemeResolver.Resolved {
        try #require(AppSchemeResolver.resolve(URL(string: url)!, root: root))
    }

    @Test
    func serves_an_existing_file_with_its_type() throws {
        let resolved = try resolve("cloudcli://app/assets/app.js", makeRoot())
        #expect(resolved.file.lastPathComponent == "app.js")
        #expect(resolved.contentType == "text/javascript; charset=utf-8")
    }

    @Test
    func client_routes_get_index_html() throws {
        let resolved = try resolve("cloudcli://app/session/abc", makeRoot())
        #expect(resolved.file.lastPathComponent == "index.html")
        #expect(resolved.contentType == "text/html; charset=utf-8")
    }

    @Test
    func traversal_gets_index_html() throws {
        let resolved = try resolve("cloudcli://app/../../secret", makeRoot())
        #expect(resolved.file.lastPathComponent == "index.html")
    }

    @Test
    func encoded_traversal_never_leaves_the_root() throws {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        for path in ["%2e%2e/\(outside.lastPathComponent)", "..%2f\(outside.lastPathComponent)", "assets/../../\(outside.lastPathComponent)"] {
            let resolved = try resolve("cloudcli://app/\(path)", root)
            #expect(resolved.file.lastPathComponent == "index.html", "\(path)")
        }
    }

    @Test
    func symlink_to_a_file_outside_the_root_gets_index_html() throws {
        let root = try makeRoot()
        let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "assets/leak.js"), withDestinationURL: outside)
        let resolved = try resolve("cloudcli://app/assets/leak.js", root)
        #expect(resolved.file.lastPathComponent == "index.html")
    }

    @Test
    func symlinked_directory_outside_the_root_gets_index_html() throws {
        let root = try makeRoot()
        let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "s.txt"))
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: outside)
        let resolved = try resolve("cloudcli://app/linked/s.txt", root)
        #expect(resolved.file.lastPathComponent == "index.html")
    }

    @Test
    func symlink_inside_the_root_is_still_served() throws {
        let root = try makeRoot()
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "alias.js"), withDestinationURL: root.appending(path: "assets/app.js"))
        let resolved = try resolve("cloudcli://app/alias.js", root)
        #expect(resolved.file.lastPathComponent == "app.js")
    }

    @Test
    func a_root_reached_through_a_symlink_still_serves_files() throws {
        let root = try makeRoot()
        let alias = FileManager.default.temporaryDirectory.appending(path: "alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        let resolved = try resolve("cloudcli://app/assets/app.js", alias)
        #expect(resolved.file.lastPathComponent == "app.js")
    }
}
