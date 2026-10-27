import XCTest
@testable import EmLoadServerKit

final class AnisetteProxyTests: XCTestCase {
    func testRouterForwardsOnlyCallerV3PathsBehindTheToken() {
        let token = "abc123abc123abcd"
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/\(token)/v3/client_info", token: token),
            .http("/v3/client_info")
        )
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "POST", target: "/\(token)/v3/get_headers?ignored=1", token: token),
            .http("/v3/get_headers")
        )
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/\(token)/v3/provisioning_session", token: token),
            .webSocket("/v3/provisioning_session")
        )
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/v3/client_info", token: token),
            .unauthorized
        )
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/\(token)/", token: token),
            .notFound
        )
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/\(token)/v3/get_headers", token: token),
            .notFound
        )
    }

    func testOpenRouterStillRefusesTheSharedRootIdentity() {
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/", token: nil),
            .notFound
        )
        XCTAssertEqual(
            AnisetteProxyRouter.decide(method: "GET", target: "/v3/client_info", token: nil),
            .http("/v3/client_info")
        )
    }

    func testUpstreamURLKeepsTheCallerPath() throws {
        let base = try XCTUnwrap(URL(string: "https://new.ani.sidestore.io"))
        let url = try XCTUnwrap(AnisetteProxyRouter.upstreamURL(base: base, path: "/v3/get_headers"))
        XCTAssertEqual(url.absoluteString, "https://new.ani.sidestore.io/v3/get_headers")
    }

    func testWebSocketAcceptMatchesTheProtocolExample() {
        XCTAssertEqual(
            WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testMaskedClientFrameRoundTrip() throws {
        let payload = Data("Hello".utf8)
        let mask: [UInt8] = [1, 2, 3, 4]
        var frame = Data([0x81, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        for (offset, byte) in payload.enumerated() {
            frame.append(byte ^ mask[offset % 4])
        }

        var decoder = WebSocketFrameDecoder()
        decoder.append(frame)
        let decoded = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(decoded, WebSocketFrame(opcode: 0x1, payload: payload))
        XCTAssertNil(try decoder.next())
    }

    func testProxyCommandKeepsATokenUnlessOpened() throws {
        let opened = try ProxyCommand.parse(arguments: ["--open", "--bind", "127.0.0.1", "--port", "1741"])
        XCTAssertNil(opened.token)
        XCTAssertEqual(opened.bindHost, "127.0.0.1")
        XCTAssertEqual(opened.upstream.absoluteString, "https://new.ani.sidestore.io")

        let locked = try ProxyCommand.parse(arguments: ["--token", "client-token-value"])
        XCTAssertEqual(locked.token, "client-token-value")
        XCTAssertThrowsError(try ProxyCommand.parse(arguments: ["--open", "--token", "client-token-value"]))
    }

    func testCustomProxyAllowsHTTPAndRegistryEntriesDoNot() {
        let proxy = AnisetteServerRegistry.customEndpoint(from: "http://127.0.0.1:1741/client-token-value")
        XCTAssertEqual(proxy?.endpoint?.absoluteString, "http://127.0.0.1:1741/client-token-value")
        XCTAssertNil(proxy?.url)

        let registry = AnisetteServer(name: "Example", address: "http://example.test", kind: 2)
        XCTAssertNil(registry.url)
        XCTAssertNil(registry.endpoint)
        XCTAssertNil(AnisetteServerRegistry.customEndpoint(from: "https://user:secret@example.test"))
    }

    func testHTTPHeadParserReadsHeadersWithoutTheBody() throws {
        let raw = Data("POST /v3/get_headers HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let parsed = try XCTUnwrap(try HTTPHeadParser.parse(raw))
        XCTAssertEqual(parsed.0.method, "POST")
        XCTAssertEqual(parsed.0.target, "/v3/get_headers")
        XCTAssertEqual(parsed.0.headers["content-length"], "2")
        XCTAssertEqual(parsed.1, raw.count - 2)
    }
}
