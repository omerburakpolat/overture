import Foundation

/// One Vercel deployment, decoded from `GET /v6/deployments`.
public struct Deployment: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Codable {
        case queued = "QUEUED"
        case building = "BUILDING"
        case initializing = "INITIALIZING"
        case ready = "READY"
        case error = "ERROR"
        case canceled = "CANCELED"
    }

    public var id: String
    public var state: State
    /// Host without scheme, e.g. `myapp-abc123.vercel.app`.
    public var url: String
    public var branch: String?
    public var target: String?   // "production" or nil (preview)
    public var createdAt: Date

    public init(id: String, state: State, url: String,
                branch: String?, target: String?, createdAt: Date) {
        self.id = id
        self.state = state
        self.url = url
        self.branch = branch
        self.target = target
        self.createdAt = createdAt
    }

    public var previewURL: URL? { URL(string: "https://\(url)") }
}

/// A Vercel project, for the link-project picker.
public struct VercelProject: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
