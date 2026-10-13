import Foundation

enum DomainLifecycleError: LocalizedError {
    case invalidInput, alreadyExists, unknownDomain, inspectionFailed
    case configurationFailed, registrationFailed, rollbackIncomplete
    case deregistrationFailed, mappingRemovalFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "invalid domain ID, display name, or selector"
        case .alreadyExists: return "domain already registered or configured; existing mapping retained"
        case .unknownDomain: return "domain not registered or configured"
        case .inspectionFailed: return "unable to inspect domain state"
        case .configurationFailed: return "Agent configuration failed; new mapping rolled back"
        case .registrationFailed: return "File Provider registration failed; new domain rolled back"
        case .rollbackIncomplete: return "domain rollback incomplete; retry removal using the domain ID"
        case .deregistrationFailed: return "File Provider removal failed; Agent mapping retained"
        case .mappingRemovalFailed: return "File Provider removed but Agent cleanup failed; retry removal using the domain ID"
        }
    }
}

/// DomainLifecycle orders registry and Agent changes without exposing selectors to the Provider.
final class DomainLifecycle {
    private let registeredIdentifiers: () throws -> [String]
    private let isConfigured: (String) throws -> Bool
    private let configure: (String, String) throws -> Void
    private let register: (String, String) throws -> Void
    private let deregister: (String) throws -> Void
    private let removeConfiguration: (String) throws -> Void

    init(registeredIdentifiers: @escaping () throws -> [String], isConfigured: @escaping (String) throws -> Bool,
         configure: @escaping (String, String) throws -> Void, register: @escaping (String, String) throws -> Void,
         deregister: @escaping (String) throws -> Void, removeConfiguration: @escaping (String) throws -> Void) {
        self.registeredIdentifiers = registeredIdentifiers; self.isConfigured = isConfigured
        self.configure = configure; self.register = register; self.deregister = deregister
        self.removeConfiguration = removeConfiguration
    }

    static func validDisplayName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 255 &&
        !value.contains("/") && !value.contains("\\") &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func add(displayName: String, remote: String, identifier: String = CloudMountDomainIdentifier.make()) throws -> String {
        guard CloudMountDomainIdentifier.isValid(identifier), Self.validDisplayName(displayName),
              !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DomainLifecycleError.invalidInput }
        let registered: [String]; let configured: Bool
        do { registered = try registeredIdentifiers(); configured = try isConfigured(identifier) }
        catch { throw DomainLifecycleError.inspectionFailed }
        guard !registered.contains(identifier), !configured else { throw DomainLifecycleError.alreadyExists }
        do { try configure(identifier, remote) }
        catch {
            do { try removeConfiguration(identifier) }
            catch { throw DomainLifecycleError.rollbackIncomplete }
            throw DomainLifecycleError.configurationFailed
        }
        do { try register(identifier, displayName) }
        catch {
            // Never purge the mapping while registration might still be live.
            do {
                if try registeredIdentifiers().contains(identifier) { try deregister(identifier) }
                try removeConfiguration(identifier)
            } catch { throw DomainLifecycleError.rollbackIncomplete }
            throw DomainLifecycleError.registrationFailed
        }
        return identifier
    }

    func remove(identifier: String) throws {
        guard CloudMountDomainIdentifier.isManaged(identifier) else { throw DomainLifecycleError.invalidInput }
        let registered: Bool; let configured: Bool
        do { registered = try registeredIdentifiers().contains(identifier); configured = try isConfigured(identifier) }
        catch { throw DomainLifecycleError.inspectionFailed }
        guard registered || configured else { throw DomainLifecycleError.unknownDomain }
        if registered {
            do { try deregister(identifier) }
            catch { throw DomainLifecycleError.deregistrationFailed }
        }
        do { try removeConfiguration(identifier) }
        catch { throw DomainLifecycleError.mappingRemovalFailed }
    }
}
