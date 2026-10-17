import CryptoKit
import Darwin
import Foundation
import Security
import Testing

@testable import GCSFCore

struct AuthTests {
    @Test func keychainQueryUsesTheSharedGroup() {
        let account = "primary"
        let query = RefreshTokenQuery.attributes(account: account)
        #expect(query.count == 7)
        #expect(query[kSecClass as String] as? String == (kSecClassGenericPassword as String))
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccessGroup as String] as? String == RuntimeBoundary.sharedGroupIdentifier)
        #expect(query[kSecAttrService as String] as? String == RuntimeBoundary.keychainService)
        #expect(query[kSecAttrAccount as String] as? String == account)
        #expect(query[kSecAttrAccessible as String] as? String == (kSecAttrAccessibleAfterFirstUnlock as String))
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func loginUsesPKCEAndStoresOnlyTheRefreshToken() async throws {
        let tokens = AuthMemoryTokens()
        let recorded = RecordedHTTP { _ in
            (200, "{\"access_token\":\"access-login\",\"refresh_token\":\"refresh-login\",\"expires_in\":120,\"token_type\":\"Bearer\"}")
        }
        defer { recorded.stop() }
        let seen = URLBox()
        let client = try OAuthClient(document: "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"csec\"}}")
        let endpoint = URL(string: "http://127.0.0.1:\(recorded.port)/token")!
        let access = try await OAuthAuthorization.login(
            client: client,
            session: "work",
            port: 0,
            tokenEndpoint: endpoint,
            tokens: tokens,
            timeout: .seconds(5),
            openBrowser: { url in
                await seen.set(url)
                await sendCallback(auth: url, state: nil, code: "auth-code")
            }
        )
        #expect(access.accessToken == "access-login")
        #expect(access.expiresIn == 120)
        #expect(await tokens.snapshot() == ["work": "refresh-login"])
        let auth = try #require(await seen.get())
        let items = URLComponents(url: auth, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        #expect(auth.host == "accounts.google.com")
        #expect(auth.path == "/o/oauth2/auth")
        #expect(query("client_id") == "cid")
        #expect(query("response_type") == "code")
        #expect(query("scope") == "https://www.googleapis.com/auth/drive")
        #expect(query("access_type") == "offline")
        #expect(query("prompt") == "consent")
        #expect(query("code_challenge_method") == "S256")
        let redirect = try #require(query("redirect_uri"))
        #expect(redirect == "http://127.0.0.1:\(port(of: redirect))/")
        let state = try #require(query("state"))
        #expect(!state.isEmpty)
        let body = try #require(recorded.bodies().first)
        let form = formFields(body)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "auth-code")
        #expect(form["redirect_uri"] == redirect)
        #expect(form["client_id"] == "cid")
        #expect(form["client_secret"] == "csec")
        let verifier = try #require(form["code_verifier"])
        #expect((43...128).contains(verifier.count))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        #expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(query("code_challenge") == codeChallenge(verifier))
        #expect(query("state") == state)
        #expect(recorded.count == 1)
        #expect(await !(tokens.snapshot().values.contains("access-login")))
    }

    @Test func mismatchedStateDoesNotExchangeTheCode() async throws {
        let tokens = AuthMemoryTokens()
        let recorded = RecordedHTTP { _ in
            (200, "{\"access_token\":\"access-login\",\"refresh_token\":\"refresh-login\"}")
        }
        defer { recorded.stop() }
        let client = OAuthClient(id: "cid", secret: "csec")
        let endpoint = URL(string: "http://127.0.0.1:\(recorded.port)/token")!
        await #expect(throws: OAuthError.stateMismatch) {
            try await OAuthAuthorization.login(
                client: client,
                session: "work",
                port: 0,
                tokenEndpoint: endpoint,
                tokens: tokens,
                timeout: .seconds(5),
                openBrowser: { url in
                    await sendCallback(auth: url, state: "wrong-state", code: "auth-code")
                }
            )
        }
        #expect(recorded.count == 0)
        #expect(await tokens.snapshot().isEmpty)
    }

    @Test func concurrentRefreshSharesOneTokenRequest() async throws {
        let tokens = AuthMemoryTokens()
        try await tokens.store(session: "work", refreshToken: "refresh-old")
        let gate = RequestGate()
        let recorded = RecordedHTTP(gate: gate) { _ in
            (200, "{\"access_token\":\"access-aaa\",\"refresh_token\":\"refresh-new\",\"expires_in\":30,\"token_type\":\"Bearer\"}")
        }
        defer { recorded.stop() }
        let endpoint = URL(string: "http://127.0.0.1:\(recorded.port)/token")!
        let manager = TokenManager(client: OAuthClient(id: "cid", secret: "csec"), tokenEndpoint: endpoint, tokens: tokens)
        let first = Task { try await manager.refresh(session: "work") }
        await gate.waitUntilArrived()
        let second = Task { try await manager.refresh(session: "work") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await manager.refreshJoinCount(session: "work") < 2 {
            if ContinuousClock.now >= deadline {
                Issue.record("second refresh did not join the in-flight request")
                break
            }
            await Task.yield()
        }
        gate.open()
        let left = try await first.value
        let right = try await second.value
        #expect(left == right)
        #expect(left.accessToken == "access-aaa")
        #expect(recorded.count == 1)
        #expect(await tokens.snapshot() == ["work": "refresh-new"])
        let form = formFields(try #require(recorded.bodies().first))
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "refresh-old")
        #expect(form["client_id"] == "cid")
        #expect(form["client_secret"] == "csec")
        #expect(await !(tokens.snapshot().values.contains("access-aaa")))
    }

    @Test func refreshKeepsTheStoredTokenWhenTheResponseOmitsOne() async throws {
        let tokens = AuthMemoryTokens()
        try await tokens.store(session: "work", refreshToken: "refresh-old")
        let recorded = RecordedHTTP { _ in
            (200, "{\"access_token\":\"access-bbb\",\"expires_in\":10,\"token_type\":\"Bearer\"}")
        }
        defer { recorded.stop() }
        let endpoint = URL(string: "http://127.0.0.1:\(recorded.port)/token")!
        let manager = TokenManager(client: OAuthClient(id: "cid", secret: "csec"), tokenEndpoint: endpoint, tokens: tokens)
        let access = try await manager.refresh(session: "work")
        #expect(access.accessToken == "access-bbb")
        #expect(await tokens.snapshot() == ["work": "refresh-old"])
        #expect(recorded.count == 1)
        await #expect(throws: OAuthError.missingRefreshToken) {
            try await manager.refresh(session: "missing")
        }
        #expect(recorded.count == 1)
    }
}

private func port(of redirect: String) -> UInt16 {
    UInt16(URL(string: redirect)?.port ?? 0)
}

private func codeChallenge(_ verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func formFields(_ body: String) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = percentDecode(String(parts[0]))
        let value = parts.count > 1 ? percentDecode(String(parts[1])) : ""
        fields[key] = value
    }
    return fields
}

private func percentDecode(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}

private func sendCallback(auth: URL, state override: String?, code: String) async {
    let items = URLComponents(url: auth, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? {
        items.first { $0.name == name }?.value
    }
    guard let redirect = value("redirect_uri"), var components = URLComponents(string: redirect) else {
        return
    }
    components.queryItems = [
        URLQueryItem(name: "code", value: code),
        URLQueryItem(name: "state", value: override ?? value("state")),
    ]
    guard let url = components.url else {
        return
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    _ = try? await session.data(from: url)
}

private actor URLBox {
    private var url: URL?

    func set(_ url: URL) {
        self.url = url
    }

    func get() -> URL? {
        url
    }
}

private actor AuthMemoryTokens: RefreshTokenStore {
    private var values: [String: String] = [:]

    func load(session: String) async throws -> String? {
        values[session]
    }

    func store(session: String, refreshToken: String) async throws {
        values[session] = refreshToken
    }

    func remove(session: String) async throws {
        values[session] = nil
    }

    func snapshot() -> [String: String] {
        values
    }
}

private final class RequestGate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let go = DispatchSemaphore(value: 0)

    func markArrived() {
        arrived.signal()
    }

    func waitUntilArrived() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.arrived.wait()
                continuation.resume()
            }
        }
    }

    func block() {
        go.wait()
    }

    func open() {
        go.signal()
    }
}

private final class RecordedHTTP: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var listenFD: Int32
    private let queue = DispatchQueue(label: "gcsf.test.token")
    private var recorded: [String] = []
    private let respond: @Sendable (String) -> (Int, String)
    private let gate: RequestGate?

    init(gate: RequestGate? = nil, respond: @escaping @Sendable (String) -> (Int, String)) {
        self.gate = gate
        self.respond = respond
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = Darwin.listen(fd, 16)
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.getsockname(fd, raw, &length)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)
        queue.async { [weak self] in
            self?.acceptLoop(fd)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    func bodies() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            serve(client)
            Darwin.close(client)
        }
    }

    private func serve(_ fd: Int32) {
        guard let body = try? readBody(fd) else {
            return
        }
        lock.lock()
        recorded.append(body)
        let ordinal = recorded.count
        let handler = respond
        lock.unlock()
        if ordinal == 1, let gate {
            gate.markArrived()
            gate.block()
        }
        let (status, payload) = handler(body)
        var bytes = Data("HTTP/1.1 \(status) OK\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n".utf8)
        bytes.append(Data(payload.utf8))
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(fd, base, raw.count)
        }
    }

    private func readBody(_ fd: Int32) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            if data.count > 65_536 {
                throw RecordedHTTPError()
            }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count <= 0 {
                throw RecordedHTTPError()
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw RecordedHTTPError()
        }
        let header = String(decoding: data.subdata(in: 0..<marker.lowerBound), as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                length = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        var body = data.subdata(in: marker.upperBound..<data.count)
        while body.count < length {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count <= 0 {
                break
            }
            body.append(contentsOf: buffer.prefix(count))
        }
        if body.count > length {
            body = body.prefix(length)
        }
        return String(decoding: body, as: UTF8.self)
    }
}

private struct RecordedHTTPError: Error {}
