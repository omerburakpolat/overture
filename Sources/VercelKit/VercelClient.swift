import Foundation

/// Vercel REST client. Read-only at v1 (deployments + projects); the token
/// is user-supplied (vercel.com/account/tokens) and lives in the Keychain —
/// never in the store, never logged.
public actor VercelClient {
    public enum ClientError: Error, Sendable {
        case unauthorized              // 401/403 — token invalid or revoked
        case rateLimited(retryAfter: TimeInterval?)
        case transport(String)
        case badResponse(status: Int)
    }

    private let session: URLSession
    private let baseURL: URL
    private let tokenProvider: @Sendable () -> String?

    /// `sessionConfiguration` is injectable so tests can stub URLProtocol.
    public init(tokenProvider: @escaping @Sendable () -> String?,
                baseURL: URL = URL(string: "https://api.vercel.com")!,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        session = URLSession(configuration: sessionConfiguration)
    }

    /// Latest deployments for a project (optionally scoped to a team).
    public func deployments(projectID: String,
                            teamID: String? = nil,
                            limit: Int = 10) async throws -> [Deployment] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v6/deployments"),
            resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "projectId", value: projectID),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let teamID { query.append(.init(name: "teamId", value: teamID)) }
        components.queryItems = query
        let value = try await get(components.url!)
        return (value["deployments"]?.arrayValue ?? [])
            .compactMap(Self.deployment(from:))
    }

    /// Projects for the link-project picker.
    public func projects(teamID: String? = nil) async throws -> [VercelProject] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v9/projects"),
            resolvingAgainstBaseURL: false)!
        if let teamID {
            components.queryItems = [.init(name: "teamId", value: teamID)]
        }
        let value = try await get(components.url!)
        return (value["projects"]?.arrayValue ?? []).compactMap { project in
            guard let id = project["id"]?.stringValue,
                  let name = project["name"]?.stringValue else { return nil }
            return VercelProject(id: id, name: name)
        }
    }

    // MARK: - Internals

    private func get(_ url: URL) async throws -> VercelJSON {
        guard let token = tokenProvider() else { throw ClientError.unauthorized }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ClientError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw ClientError.rateLimited(retryAfter: retry)
        default:
            throw ClientError.badResponse(status: http.statusCode)
        }
        return (try? JSONDecoder().decode(VercelJSON.self, from: data))
            ?? .null
    }

    /// Tolerant mapping: v6 has drifted between `state`/`readyState` and
    /// `createdAt`/`created` (ms epoch); branch rides in meta for git deploys.
    static func deployment(from value: VercelJSON) -> Deployment? {
        guard let id = value["uid"]?.stringValue ?? value["id"]?.stringValue,
              let url = value["url"]?.stringValue else { return nil }
        let stateRaw = value["state"]?.stringValue
            ?? value["readyState"]?.stringValue ?? ""
        let state = Deployment.State(rawValue: stateRaw) ?? .queued
        let createdMS = value["createdAt"]?.numberValue
            ?? value["created"]?.numberValue ?? 0
        return Deployment(
            id: id,
            state: state,
            url: url,
            branch: value["meta"]?["githubCommitRef"]?.stringValue,
            target: value["target"]?.stringValue,
            createdAt: Date(timeIntervalSince1970: createdMS / 1000))
    }
}

/// Minimal Sendable JSON — VercelKit has no dependency on ProcessCore, so it
/// carries its own copy of the tolerant-JSON idiom.
public enum VercelJSON: Sendable, Codable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([VercelJSON]), object([String: VercelJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([VercelJSON].self) { self = .array(a) }
        else if let o = try? container.decode([String: VercelJSON].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrepresentable JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    subscript(key: String) -> VercelJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    var arrayValue: [VercelJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
