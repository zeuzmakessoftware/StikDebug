import CryptoKit
import Foundation

/// A personalized image and trust cache must match the same Apple build identity.
struct DDIManifest {
    static let fileNames = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
    let data: Data
    let buildVersion: String
    private let identities: [[String: Any]]

    init(data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let manifest = plist as? [String: Any],
              let buildVersion = manifest["ProductBuildVersion"] as? String,
              !buildVersion.isEmpty,
              let identities = manifest["BuildIdentities"] as? [[String: Any]],
              identities.contains(where: { identity in
                  guard let entries = identity["Manifest"] as? [String: Any] else { return false }
                  return entries["PersonalizedDMG"] != nil && entries["LoadableTrustCache"] != nil
              }) else {
            throw DDIDownloadError.invalidManifest
        }
        self.data = data
        self.buildVersion = buildVersion
        self.identities = identities
    }

    func validate(in directory: URL) throws {
        let imageHash = try Self.digest(of: directory.appendingPathComponent("Image.dmg"))
        let trustHash = try Self.digest(of: directory.appendingPathComponent("Image.dmg.trustcache"))
        guard identities.contains(where: { identity in
            guard let entries = identity["Manifest"] as? [String: [String: Any]] else { return false }
            return entries["PersonalizedDMG"]?["Digest"] as? Data == imageHash
                && entries["LoadableTrustCache"]?["Digest"] as? Data == trustHash
        }) else {
            throw DDIDownloadError.mismatchedFiles
        }
    }

    /// Apple seed builds (e.g. 27A5228h) precede the release (e.g. 27A123),
    /// despite having a larger numeric build component.
    func isNewer(than other: DDIManifest) -> Bool {
        Self.compareBuilds(buildVersion, other.buildVersion) == .orderedDescending
    }

    static func compareBuilds(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ value: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: "^([0-9]+)([A-Z]+)([0-9]+)([a-z]*)$"),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
            return (1...4).map { String(value[Range(match.range(at: $0), in: value)!]) }
        }
        guard let left = parts(lhs), let right = parts(rhs) else { return lhs.compare(rhs, options: .numeric) }
        for index in [0, 1] {
            let result = left[index].compare(right[index], options: .numeric)
            if result != .orderedSame { return result }
        }
        if left[3].isEmpty != right[3].isEmpty { return left[3].isEmpty ? .orderedDescending : .orderedAscending }
        // Seed build numbers carry a 5000 offset; release candidates drop it
        // while sometimes retaining a suffix (27A266a follows 27A5228h).
        func buildNumber(_ part: String) -> Int {
            let number = Int(part) ?? 0
            return (5000..<10000).contains(number) ? number - 5000 : number
        }
        let leftBuild = buildNumber(left[2])
        let rightBuild = buildNumber(right[2])
        if leftBuild != rightBuild { return leftBuild > rightBuild ? .orderedDescending : .orderedAscending }
        return left[3].compare(right[3])
    }

    /// Supports both normalized downloads and Xcode's Restore directory filenames.
    func copyPayloads(from source: URL, to destination: URL, fileManager: FileManager) throws {
        for (key, name) in [("PersonalizedDMG", "Image.dmg"), ("LoadableTrustCache", "Image.dmg.trustcache")] {
            let normalized = source.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            let root = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard normalized.path.hasPrefix(root) else { throw DDIDownloadError.invalidManifest }
            let paths = identities.compactMap { identity -> String? in
                let entries = identity["Manifest"] as? [String: [String: Any]]
                return (entries?[key]?["Info"] as? [String: Any])?["Path"] as? String
            }
            var candidates = [normalized]
            for path in paths {
                let candidate = source.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard candidate.path.hasPrefix(root) else { throw DDIDownloadError.invalidManifest }
                candidates.append(candidate)
            }
            guard let file = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                throw DDIDownloadError.missingFile(name)
            }
            try fileManager.copyItem(at: file, to: destination.appendingPathComponent(name))
        }
        try data.write(to: destination.appendingPathComponent("BuildManifest.plist"))
        try validate(in: destination)
    }

    private static func digest(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw DDIDownloadError.missingFile(url.lastPathComponent) }
        return Data(SHA384.hash(data: data))
    }
}

enum DDIDownloadError: LocalizedError {
    case invalidResponse
    case badStatus(Int)
    case invalidManifest
    case mismatchedFiles
    case missingFile(String)
    case updateInProgress

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The DDI server returned an invalid response."
        case .badStatus(let status): return "The DDI server returned HTTP \(status)."
        case .invalidManifest: return "Select a personalized iOS DDI folder containing BuildManifest.plist, the image, and its trust cache."
        case .mismatchedFiles: return "The DDI image and trust cache do not match the build manifest. Download or import all three files from the same Xcode image. Your previous files have been kept."
        case .missingFile(let name): return "The DDI folder is missing a nonempty \(name)."
        case .updateInProgress: return "A DDI update is already in progress. Please try again when it finishes."
        }
    }
}
