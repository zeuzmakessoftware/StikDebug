import Foundation

/// Publishes complete, verified generations. A mount keeps its generation even during an update.
actor DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()
    typealias Fetch = @Sendable (URL) async throws -> Data
    typealias Progress = @Sendable (Double, String) -> Void

    private struct Installation: Codable {
        let directory: String
        let source: String
    }

    private let root: URL
    private let bundledDirectory: URL?
    private let fetch: Fetch
    private let fileManager: FileManager
    private var preparation: Task<URL, Error>?
    private var isUpdating = false
    private var didPrepareStorage = false
    private var preparedDirectory: URL?

    init(
        root: URL = URL.documentsDirectory.appendingPathComponent("DDI"),
        bundledDirectory: URL? = Bundle.main.url(forResource: "BundledDDI", withExtension: nil),
        fileManager: FileManager = .default,
        fetch: @escaping Fetch = { try await DeveloperDiskImageService.fetchRemoteFile($0) }
    ) {
        self.root = root
        self.bundledDirectory = bundledDirectory
        self.fileManager = fileManager
        self.fetch = fetch
    }

    /// Checks for a newer manifest once per launch; an imported image stays selected.
    func prepare() async throws -> URL {
        if let preparation { return try await preparation.value }
        if let preparedDirectory { return preparedDirectory }
        let task = Task { try await update(force: false, progress: nil) }
        preparation = task
        defer { preparation = nil }
        let directory = try await task.value
        preparedDirectory = directory
        return directory
    }

    func downloadMissingFiles() async throws {
        _ = try await prepare()
    }

    /// Import Xcode's Restore folder (or the normalized folder exported by this fork).
    @discardableResult
    func importDirectory(_ selectedDirectory: URL) throws -> String {
        guard preparation == nil, !isUpdating else { throw DDIDownloadError.updateInProgress }
        try prepareStorage()
        let restore = selectedDirectory.appendingPathComponent("Restore", isDirectory: true)
        let source = fileManager.fileExists(atPath: restore.appendingPathComponent("BuildManifest.plist").path)
            ? restore : selectedDirectory
        let directory = try install(from: source, source: "imported")
        preparedDirectory = directory
        return try readManifest(in: directory).buildVersion
    }

    @discardableResult
    func redownload(progressHandler: Progress? = nil) async throws -> URL {
        guard preparation == nil else { throw DDIDownloadError.updateInProgress }
        let directory = try await update(force: true, progress: progressHandler)
        preparedDirectory = directory
        return directory
    }

    private func update(force: Bool, progress: Progress?) async throws -> URL {
        guard !isUpdating else { throw DDIDownloadError.updateInProgress }
        isUpdating = true
        defer { isUpdating = false }
        try prepareStorage()

        var installed = currentInstallation()
        var current = installed.map { root.appendingPathComponent($0.directory, isDirectory: true) }
        if current == nil, let legacy = try? readManifest(in: root),
           (try? legacy.validate(in: root)) != nil {
            current = try install(from: root, source: "legacy")
            installed = currentInstallation()
        }

        // Do not replace a user-selected Xcode image on the next launch.
        if !force, installed?.source == "imported", let current { return current }

        if let bundledDirectory, let bundled = try? readManifest(in: bundledDirectory) {
            let existing = current.flatMap { try? readManifest(in: $0) }
            if existing.map({ bundled.isNewer(than: $0) }) ?? true {
                current = try install(from: bundledDirectory, source: "bundled")
            }
        }

        do {
            progress?(0, "Checking for a newer developer disk image…")
            let manifestData = try await fetch(Self.remoteURL("BuildManifest.plist"))
            let remote = try DDIManifest(data: manifestData)
            if let current, let existing = try? readManifest(in: current) {
                // The bundled or imported Xcode image may be newer than the mirror.
                if existing.isNewer(than: remote)
                    || (!force && remote.data == existing.data) {
                    progress?(1, "Keeping DDI build \(existing.buildVersion).")
                    return current
                }
            }
            let staging = try makeStagingDirectory()
            defer { try? fileManager.removeItem(at: staging) }
            try manifestData.write(to: staging.appendingPathComponent("BuildManifest.plist"))
            for (index, name) in DDIManifest.fileNames.dropFirst().enumerated() {
                progress?(Double(index + 1) / 3, "Downloading \(name)…")
                let data = try await fetch(Self.remoteURL(name))
                try Task.checkCancellation()
                try data.write(to: staging.appendingPathComponent(name))
            }
            // Reject mixed revisions if the mirror changed during the download.
            try remote.validate(in: staging)
            let result = try publish(staging, source: "downloaded")
            progress?(1, "DDI build \(remote.buildVersion) ready.")
            return result
        } catch {
            if !force, let current { return current } // Offline launches can use a verified cache.
            throw error
        }
    }

    private func prepareStorage() throws {
        guard !didPrepareStorage else { return }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let active = currentInstallation()?.directory
        // No mount has received a path yet in this process. Retire previous generations now.
        for entry in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if (entry.lastPathComponent.hasPrefix("set-") || entry.lastPathComponent.hasPrefix("staging-")),
               entry.lastPathComponent != active {
                try? fileManager.removeItem(at: entry)
            }
        }
        didPrepareStorage = true
    }

    private func currentInstallation() -> Installation? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("current.json")),
              let installation = try? JSONDecoder().decode(Installation.self, from: data),
              installation.directory.hasPrefix("set-"),
              UUID(uuidString: String(installation.directory.dropFirst(4))) != nil else { return nil }
        let directory = root.appendingPathComponent(installation.directory, isDirectory: true)
        guard let manifest = try? readManifest(in: directory),
              (try? manifest.validate(in: directory)) != nil else { return nil }
        return installation
    }

    private func readManifest(in directory: URL) throws -> DDIManifest {
        try DDIManifest(data: Data(contentsOf: directory.appendingPathComponent("BuildManifest.plist")))
    }

    private func makeStagingDirectory() throws -> URL {
        let directory = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func install(from directory: URL, source: String) throws -> URL {
        let manifest = try readManifest(in: directory)
        let staging = try makeStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }
        try manifest.copyPayloads(from: directory, to: staging, fileManager: fileManager)
        return try publish(staging, source: source)
    }

    private func publish(_ staging: URL, source: String) throws -> URL {
        let name = "set-\(UUID().uuidString)"
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.moveItem(at: staging, to: directory)
        do {
            let metadata = try JSONEncoder().encode(Installation(directory: name, source: source))
            try metadata.write(to: root.appendingPathComponent("current.json"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return directory
    }

    private static func remoteURL(_ name: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/")!.appendingPathComponent(name)
    }

    static func fetchRemoteFile(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DDIDownloadError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw DDIDownloadError.badStatus(response.statusCode) }
        return data
    }
}

func redownloadDDI(progressHandler: DeveloperDiskImageService.Progress? = nil) async throws {
    try await DeveloperDiskImageService.shared.redownload(progressHandler: progressHandler)
}
