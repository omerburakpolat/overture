import Foundation
import Testing
@testable import VercelKit

/// URLProtocol stub: per-test canned responses keyed by path.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body) = Self.responses[path] ?? (404, "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedClient() -> VercelClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return VercelClient(tokenProvider: { "test-token" },
                        sessionConfiguration: configuration)
}

@Suite(.serialized) struct VercelClientTests {
    @Test func deploymentsDecode() async throws {
        StubProtocol.responses = ["/v6/deployments": (200, """
        {"deployments":[
          {"uid":"dpl_1","state":"READY","url":"app-abc.vercel.app",
           "meta":{"githubCommitRef":"overture/fix-login-3fa9c2d1"},
           "target":"production","createdAt":1756500000000},
          {"uid":"dpl_2","readyState":"BUILDING","url":"app-def.vercel.app",
           "created":1756500100000}
        ]}
        """)]
        let deployments = try await stubbedClient()
            .deployments(projectID: "prj_x")
        #expect(deployments.count == 2)
        #expect(deployments[0].state == .ready)
        #expect(deployments[0].branch == "overture/fix-login-3fa9c2d1")
        #expect(deployments[0].target == "production")
        #expect(deployments[1].state == .building) // readyState fallback
        #expect(deployments[0].previewURL?.absoluteString
                == "https://app-abc.vercel.app")
    }

    @Test func unknownStateDegradesToQueued() async throws {
        StubProtocol.responses = ["/v6/deployments": (200, """
        {"deployments":[{"uid":"d","state":"SOMETHING_NEW","url":"x.dev"}]}
        """)]
        let deployments = try await stubbedClient()
            .deployments(projectID: "p")
        #expect(deployments[0].state == .queued)
    }

    @Test func unauthorizedThrows() async {
        StubProtocol.responses = ["/v6/deployments": (401, "{}")]
        await #expect(throws: VercelClient.ClientError.self) {
            _ = try await stubbedClient().deployments(projectID: "p")
        }
    }

    @Test func missingTokenNeverHitsNetwork() async {
        let client = VercelClient(tokenProvider: { nil })
        await #expect(throws: VercelClient.ClientError.self) {
            _ = try await client.deployments(projectID: "p")
        }
    }

    @Test func projectsDecode() async throws {
        StubProtocol.responses = ["/v9/projects": (200, """
        {"projects":[{"id":"prj_1","name":"my-app"}]}
        """)]
        let projects = try await stubbedClient().projects()
        #expect(projects == [VercelProject(id: "prj_1", name: "my-app")])
    }
}
