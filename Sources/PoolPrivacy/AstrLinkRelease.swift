import Foundation

/// One published AstrLink Guard release: its version tag, the commit it names, and the INT8 files
/// Pool runs with the size and SHA-256 the publisher recorded for them.
public struct AstrLinkRelease: Codable, Equatable, Sendable {
    public var version: String
    public var revision: String
    public var artifacts: [PrivacyModelArtifact]
    public init(version: String, revision: String, artifacts: [PrivacyModelArtifact]) {
        self.version = version; self.revision = revision; self.artifacts = artifacts
    }

    static let repository = "https://huggingface.co/QuantumNous/astrlink-guard"
    static let api = "https://huggingface.co/api/models/QuantumNous/astrlink-guard"
    static func file(_ path: String, revision: String) -> URL { URL(string: "\(repository)/resolve/\(revision)/\(path)")! }

    /// The files Pool loads, in the order it loads them.
    public static let filenames = ["model_int8.onnx", "model_int8.onnx_data", "tokenizer.json"]
    /// The token labels Pool decodes. A release that changes them needs a newer Pool.
    static let labels = ["O", "B-email", "I-email", "B-phone", "I-phone", "B-account", "I-account", "B-payment_card",
                         "I-payment_card", "B-ip_address", "I-ip_address", "B-url", "I-url", "B-common_secret",
                         "I-common_secret", "B-private_address", "I-private_address", "B-private_date", "I-private_date",
                         "B-private_person", "I-private_person"]

    /// A release Pool can run: a dotted version, a full commit id and exactly the files it loads,
    /// each bounded and with a well-formed checksum.
    var isWellFormed: Bool {
        Self.version(version) != nil && Self.commit(revision)
            && artifacts.map(\.filename) == Self.filenames
            && artifacts.allSatisfy { $0.revision == revision && (1...(64 * 1024 * 1024)).contains($0.bytes) && Self.digest($0.sha256) }
    }
    static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }
    static func newer(_ a: String, than b: String) -> Bool {
        guard let x = version(a), let y = version(b) else { return false }
        return y.lexicographicallyPrecedes(x)
    }
    static func commit(_ text: String) -> Bool { text.count == 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    static func digest(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
}

public enum AstrLinkUpdate: Equatable, Sendable {
    case none
    case available(AstrLinkRelease)
    /// The publisher released a version this Pool cannot run safely, such as other labels or license.
    case needsNewerApp(String)
}

/// Finds the newest published release. Only public metadata is read; no text leaves the Mac.
public protocol AstrLinkReleaseSource: Sendable {
    func latest() async throws -> AstrLinkUpdate
}

public struct OfficialAstrLinkReleases: AstrLinkReleaseSource {
    let downloader: any PrivacyModelDownloader
    public init(downloader: any PrivacyModelDownloader = OfficialPrivacyModelDownloader()) { self.downloader = downloader }

    public func latest() async throws -> AstrLinkUpdate {
        let refs = try await downloader.metadata(URL(string: AstrLinkRelease.api + "/refs")!, limit: 256 * 1024)
        guard let tag = try Self.newestTag(refs) else { return .none }
        let info = try await downloader.metadata(URL(string: AstrLinkRelease.api + "/revision/v" + tag)!, limit: 4 * 1024 * 1024)
        let (revision, license) = try Self.revision(info)
        guard license == "apache-2.0" else { return .needsNewerApp(tag) }
        let labels = try await downloader.metadata(AstrLinkRelease.file("int8/labels.json", revision: revision), limit: 64 * 1024)
        guard try Self.compatible(labels) else { return .needsNewerApp(tag) }
        let sums = try await downloader.metadata(AstrLinkRelease.file("int8/CHECKSUMS.json", revision: revision), limit: 64 * 1024)
        let release = try Self.release(version: tag, revision: revision, checksums: sums)
        return .available(release)
    }

    /// The highest `vX.Y.Z` tag, without its `v`.
    static func newestTag(_ data: Data) throws -> String? {
        struct Refs: Decodable { struct Ref: Decodable { var name: String }; var tags: [Ref] }
        guard let refs = try? JSONDecoder().decode(Refs.self, from: data) else { throw PrivacyFailure.modelFailed }
        return refs.tags.compactMap { $0.name.hasPrefix("v") ? String($0.name.dropFirst()) : nil }
            .filter { AstrLinkRelease.version($0) != nil }
            .max { AstrLinkRelease.version($0)!.lexicographicallyPrecedes(AstrLinkRelease.version($1)!) }
    }
    static func revision(_ data: Data) throws -> (String, String?) {
        struct Info: Decodable { struct Card: Decodable { var license: String? }; var sha: String; var cardData: Card? }
        guard let info = try? JSONDecoder().decode(Info.self, from: data), AstrLinkRelease.commit(info.sha) else { throw PrivacyFailure.modelFailed }
        return (info.sha, info.cardData?.license?.lowercased())
    }
    static func compatible(_ data: Data) throws -> Bool {
        struct Labels: Decodable { var id2label: [String: String] }
        guard let labels = try? JSONDecoder().decode(Labels.self, from: data) else { throw PrivacyFailure.modelFailed }
        return labels.id2label == Dictionary(uniqueKeysWithValues: AstrLinkRelease.labels.enumerated().map { (String($0.offset), $0.element) })
    }
    static func release(version: String, revision: String, checksums: Data) throws -> AstrLinkRelease {
        struct Entry: Decodable { var sha256: String; var size: Int }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: checksums) else { throw PrivacyFailure.modelFailed }
        let artifacts = try AstrLinkRelease.filenames.map { name -> PrivacyModelArtifact in
            guard let entry = entries[name] else { throw PrivacyFailure.modelFailed }
            return PrivacyModelArtifact(filename: name, bytes: entry.size, sha256: entry.sha256.lowercased(), revision: revision)
        }
        let release = AstrLinkRelease(version: version, revision: revision, artifacts: artifacts)
        guard release.isWellFormed else { throw PrivacyFailure.modelFailed }
        return release
    }
}
