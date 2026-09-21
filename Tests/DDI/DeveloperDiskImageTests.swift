import CryptoKit
import Foundation
import Testing
@testable import DDIKit

private struct Fixture {
    let files: [String: Data]

    init(build: String = "27A123", content: String = "current") throws {
        let image = Data("image-\(content)".utf8)
        let trust = Data("trust-\(content)".utf8)
        let manifest: [String: Any] = [
            "ProductBuildVersion": build,
            "BuildIdentities": [["Manifest": [
                "PersonalizedDMG": ["Digest": Data(SHA384.hash(data: image)), "Info": ["Path": "Image.dmg"]],
                "LoadableTrustCache": ["Digest": Data(SHA384.hash(data: trust)), "Info": ["Path": "Image.dmg.trustcache"]]
            ]]]
        ]
        files = [
            "BuildManifest.plist": try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0),
            "Image.dmg": image,
            "Image.dmg.trustcache": trust
        ]
    }

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
    }
}

private actor Server {
    var files: [String: Data]
    var requests: [String] = []
    var fail = false
    var delay = false
    init(_ fixture: Fixture) { files = fixture.files }
    func replace(_ files: [String: Data]) { self.files = files }
    func setFailure() { fail = true }
    func setDelay() { delay = true }
    func read(_ url: URL) async throws -> Data {
        requests.append(url.lastPathComponent)
        if delay { try await Task.sleep(nanoseconds: 50_000_000) }
        if fail { throw URLError(.notConnectedToInternet) }
        guard let data = files[url.lastPathComponent] else { throw DDIDownloadError.badStatus(404) }
        return data
    }
}

struct DeveloperDiskImageTests {
    private func withDirectory(_ test: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await test(directory)
    }

    private func service(_ directory: URL, _ server: Server, bundle: URL? = nil) -> DeveloperDiskImageService {
        DeveloperDiskImageService(root: directory, bundledDirectory: bundle, fetch: { try await server.read($0) })
    }

    @Test func testDownloadsAndValidatesCompleteSet() async throws {
        try await withDirectory { root in
            let fixture = try Fixture()
            let server = Server(fixture)
            let directory = try await service(root, server).prepare()
            for (name, data) in fixture.files {
                #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == data)
            }
        }
    }

    @Test func testNewLaunchRefreshesStaleManifest() async throws {
        try await withDirectory { root in
            let old = try Fixture(build: "26F1", content: "old")
            let server = Server(old)
            _ = try await service(root, server).prepare()
            let latest = try Fixture()
            await server.replace(latest.files)
            let directory = try await service(root, server).prepare()
            #expect(try Data(contentsOf: directory.appendingPathComponent("Image.dmg")) == latest.files["Image.dmg"])
        }
    }

    @Test func testUnchangedManifestDoesNotRedownloadPayloads() async throws {
        try await withDirectory { root in
            let server = Server(try Fixture())
            _ = try await service(root, server).prepare()
            _ = try await service(root, server).prepare()
            let requests = await server.requests
            #expect(requests == ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"])
        }
    }

    @Test func testFailedRefreshKeepsPreviousGeneration() async throws {
        try await withDirectory { root in
            let fixture = try Fixture()
            let server = Server(fixture)
            let service = service(root, server)
            let original = try await service.prepare()
            var broken = try Fixture(build: "27B1", content: "new").files
            broken["Image.dmg.trustcache"] = fixture.files["Image.dmg.trustcache"]
            await server.replace(broken)
            do {
                try await service.redownload()
                Issue.record("Mixed revisions must be rejected")
            } catch DDIDownloadError.mismatchedFiles { }
            let current = try await service.prepare()
            #expect(current == original)
            #expect(try Data(contentsOf: original.appendingPathComponent("Image.dmg")) == fixture.files["Image.dmg"])
        }
    }

    @Test func testOfflineLaunchUsesVerifiedCache() async throws {
        try await withDirectory { root in
            let server = Server(try Fixture())
            let original = try await service(root, server).prepare()
            await server.setFailure()
            let current = try await service(root, server).prepare()
            #expect(current == original)
        }
    }

    @Test func testPartialLegacyCacheIsReplacedAsASet() async throws {
        try await withDirectory { root in
            try Data("old".utf8).write(to: root.appendingPathComponent("Image.dmg"))
            let fixture = try Fixture()
            let directory = try await service(root, Server(fixture)).prepare()
            #expect(try Data(contentsOf: directory.appendingPathComponent("Image.dmg")) == fixture.files["Image.dmg"])
        }
    }

    @Test func testNewerBundleIsNeverDowngradedToMirror() async throws {
        try await withDirectory { root in
            let bundle = root.appendingPathComponent("bundle")
            let latest = try Fixture(build: "27A999", content: "latest")
            try latest.write(to: bundle)
            let server = Server(try Fixture(build: "27A123", content: "old"))
            let service = service(root, server, bundle: bundle)
            let first = try await service.prepare()
            let refreshed = try await service.redownload()
            #expect(first == refreshed)
            #expect(try Data(contentsOf: first.appendingPathComponent("Image.dmg")) == latest.files["Image.dmg"])
        }
    }

    @Test func testConcurrentPreparationSharesOneDownload() async throws {
        try await withDirectory { root in
            let server = Server(try Fixture())
            await server.setDelay()
            let service = service(root, server)
            async let first = service.prepare()
            async let second = service.prepare()
            let directories = try await (first, second)
            #expect(directories.0 == directories.1)
            let requests = await server.requests
            #expect(requests.count == 3)
        }
    }

    @Test func testRefreshLeavesMountSnapshotReadable() async throws {
        try await withDirectory { root in
            let fixture = try Fixture()
            let server = Server(fixture)
            let service = service(root, server)
            let snapshot = try await service.prepare()
            await server.replace(try Fixture(build: "27B1", content: "new").files)
            let updated = try await service.redownload()
            #expect(snapshot != updated)
            #expect(try Data(contentsOf: snapshot.appendingPathComponent("Image.dmg")) == fixture.files["Image.dmg"])
        }
    }

    @Test func testInvalidManifestIsRejected() throws {
        #expect(throws: (any Error).self) { try DDIManifest(data: Data("<html>server error</html>".utf8)) }
        let cryptex = try PropertyListSerialization.data(fromPropertyList: [
            "ProductBuildVersion": "27A123", "BuildIdentities": [["Manifest": ["Cryptex1,GenericDmg": [:]]]]
        ], format: .xml, options: 0)
        #expect(throws: (any Error).self) { try DDIManifest(data: cryptex) }
    }

    @Test func testReleaseSupersedesSeedBuildWithLargerNumber() {
        #expect(DDIManifest.compareBuilds("27A123", "27A5228h") == .orderedDescending)
        #expect(DDIManifest.compareBuilds("27A5228h", "27A123") == .orderedAscending)
        #expect(DDIManifest.compareBuilds("27B5001a", "27A123") == .orderedDescending)
    }
}
