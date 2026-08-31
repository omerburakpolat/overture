import Foundation
import ProcessCore

/// Typed view of the `initialize` control response — a capability goldmine
/// (M0 finding #2): slash commands for composer autocomplete, the model list
/// for the picker (never hardcode models), account for auth display.
public struct InitializeInfo: Sendable {
    public struct SlashCommand: Sendable, Equatable {
        public var name: String
        public var description: String
    }

    public struct Model: Sendable, Equatable {
        public var id: String          // the CLI's `value` (alias or full id)
        public var displayName: String
        public var supportsEffort: Bool
        public var effortLevels: [String]
    }

    public var commands: [SlashCommand]
    public var models: [Model]
    public var currentPermissionMode: String?
    public var accountEmail: String?
    public var raw: JSONValue

    public init?(from response: ControlResponse) {
        guard response.isSuccess else { return nil }
        let payload = response.payload
        commands = (payload["commands"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return SlashCommand(name: name,
                                description: entry["description"]?.stringValue ?? "")
        }
        models = (payload["models"]?.arrayValue ?? []).compactMap { entry in
            // Tolerate both string entries and {value, displayName, …}.
            if let id = entry.stringValue {
                return Model(id: id, displayName: id,
                             supportsEffort: false, effortLevels: [])
            }
            guard let id = entry["value"]?.stringValue
                ?? entry["id"]?.stringValue else { return nil }
            return Model(
                id: id,
                displayName: entry["displayName"]?.stringValue
                    ?? entry["name"]?.stringValue ?? id,
                supportsEffort: entry["supportsEffort"]?.boolValue ?? false,
                effortLevels: (entry["supportedEffortLevels"]?.arrayValue ?? [])
                    .compactMap(\.stringValue))
        }
        currentPermissionMode = payload["current_permission_mode"]?.stringValue
        accountEmail = payload["account"]?["email"]?.stringValue
            ?? payload["account"]?.stringValue
        raw = payload
    }
}
