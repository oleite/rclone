import Foundation

enum DomainConfigurationStoreError: LocalizedError {
    case malformedConfiguration
    case unsupportedVersion(Int)
    case domainNotConfigured(String)
    case invalidConfigurationInput

    var errorDescription: String? {
        switch self {
        case .malformedConfiguration: return "CloudMount domain configuration is malformed"
        case .unsupportedVersion(let version): return "unsupported CloudMount domain configuration version \(version)"
        case .domainNotConfigured(let domain): return "CloudMount domain is not configured: \(domain)"
        case .invalidConfigurationInput: return "CloudMount domain identifier and remote must not be empty"
        }
    }
}

final class DomainConfigurationStore {
    private struct Entry: Codable { let remote: String }
    private struct Configuration: Codable {
        var version: Int = 1
        var domains: [String: Entry] = [:]
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) { self.fileURL = fileURL }

    static func applicationSupportStore(fileManager: FileManager = .default) throws -> DomainConfigurationStore {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DomainConfigurationStore(fileURL: support.appendingPathComponent("Rclone CloudMount", isDirectory: true).appendingPathComponent("domains.json"))
    }

    func configure(domainIdentifier: String, remote: String) throws {
        guard !domainIdentifier.isEmpty, !remote.isEmpty else { throw DomainConfigurationStoreError.invalidConfigurationInput }
        try locked {
            var configuration = try readUnlocked()
            configuration.domains[domainIdentifier] = Entry(remote: remote)
            try writeUnlocked(configuration)
        }
    }

    func remove(domainIdentifier: String) throws {
        try locked {
            var configuration = try readUnlocked()
            configuration.domains.removeValue(forKey: domainIdentifier)
            try writeUnlocked(configuration)
        }
    }

    func isConfigured(domainIdentifier: String) throws -> Bool {
        try locked { try readUnlocked().domains[domainIdentifier] != nil }
    }

    func remote(domainIdentifier: String) throws -> String {
        try locked {
            guard let remote = try readUnlocked().domains[domainIdentifier]?.remote else {
                throw DomainConfigurationStoreError.domainNotConfigured(domainIdentifier)
            }
            return remote
        }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }

    private func readUnlocked() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Configuration() }
        let data = try Data(contentsOf: fileURL)
        let configuration: Configuration
        do { configuration = try JSONDecoder().decode(Configuration.self, from: data) }
        catch { throw DomainConfigurationStoreError.malformedConfiguration }
        guard configuration.version == 1 else { throw DomainConfigurationStoreError.unsupportedVersion(configuration.version) }
        return configuration
    }

    private func writeUnlocked(_ configuration: Configuration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
