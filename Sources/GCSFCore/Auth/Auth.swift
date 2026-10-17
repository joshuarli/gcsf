import CryptoKit
import Darwin
import Foundation
import Security

public enum RefreshTokenQuery {
    public static func attributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: RuntimeBoundary.sharedGroupIdentifier,
            kSecAttrService as String: RuntimeBoundary.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

public protocol RefreshTokenStore: Sendable {
    func load(session: String) async throws -> String?
    func store(session: String, refreshToken: String) async throws
    func remove(session: String) async throws
}

public enum KeychainStoreError: Error, Equatable, Sendable {
    case status(OSStatus)
    case unreadable
}

public struct KeychainRefreshTokenStore: RefreshTokenStore {
    public init() {}

    public func load(session: String) async throws -> String? {
        var query = RefreshTokenQuery.attributes(account: session)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                throw KeychainStoreError.unreadable
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.status(status)
        }
    }

    public func store(session: String, refreshToken: String) async throws {
        guard let data = refreshToken.data(using: .utf8), !refreshToken.isEmpty else {
            throw KeychainStoreError.unreadable
        }
        let base = RefreshTokenQuery.attributes(account: session)
        let deleted = SecItemDelete(base as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw KeychainStoreError.status(deleted)
        }
        var query = base
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.status(status)
        }
    }

    public func remove(session: String) async throws {
        let status = SecItemDelete(RefreshTokenQuery.attributes(account: session) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }
}

public struct OAuthClient: Sendable, Equatable {
    public let id: String
    public let secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }

    public init(document: String) throws {
        let decoded: InstalledClientDocument
        do {
            decoded = try JSONDecoder().decode(InstalledClientDocument.self, from: Data(document.utf8))
        } catch {
            throw OAuthError.invalidClientDocument
        }
        let id = decoded.installed.clientId
        let secret = decoded.installed.clientSecret
        guard !id.isEmpty, !secret.isEmpty else {
            throw OAuthError.invalidClientDocument
        }
        self.id = id
        self.secret = secret
    }
}

public enum OAuthDrive {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let scope = "https://www.googleapis.com/auth/drive"

    public static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/"
    }
}

public struct OAuthAccess: Sendable, Equatable {
    public let accessToken: String
    public let expiresIn: Int?

    public init(accessToken: String, expiresIn: Int?) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
    }
}

public enum OAuthError: Error, Equatable, Sendable {
    case invalidClientDocument
    case stateMismatch
    case missingCode
    case providerRejected
    case missingRefreshToken
    case notStored
    case tokenRejected(Int)
    case malformedTokenResponse
    case timedOut
    case loopbackFailed
}

public enum OAuthAuthorization {
    public static func login(
        client: OAuthClient,
        session name: String,
        port: UInt16,
        tokenEndpoint: URL = OAuthDrive.tokenEndpoint,
        tokens: any RefreshTokenStore,
        timeout: Duration = .seconds(300),
        openBrowser: @escaping @Sendable (URL) async -> Void
    ) async throws -> OAuthAccess {
        let verifier = PKCE.verifier()
        let state = PKCE.state()
        let listener = try LoopbackRedirect(port: port, timeout: timeout)
        defer { listener.stop() }
        let redirect = OAuthDrive.redirectURI(port: listener.port)
        let url = try authorizationURL(
            client: client,
            redirect: redirect,
            state: state,
            challenge: PKCE.challenge(verifier)
        )
        await openBrowser(url)
        let callback = try await listener.nextCallback()
        guard callback.state == state else {
            throw OAuthError.stateMismatch
        }
        if callback.error != nil {
            throw OAuthError.providerRejected
        }
        guard let code = callback.code, !code.isEmpty else {
            throw OAuthError.missingCode
        }
        let http = OAuthHTTP.session()
        defer { http.finishTasksAndInvalidate() }
        let granted = try await OAuthHTTP.post(
            endpoint: tokenEndpoint,
            fields: [
                ("client_id", client.id),
                ("client_secret", client.secret),
                ("code", code),
                ("grant_type", "authorization_code"),
                ("redirect_uri", redirect),
                ("code_verifier", verifier),
            ],
            session: http
        )
        guard let refresh = granted.refreshToken, !refresh.isEmpty else {
            throw OAuthError.missingRefreshToken
        }
        try await tokens.store(session: name, refreshToken: refresh)
        let stored = try await tokens.load(session: name)
        guard stored == refresh else {
            throw OAuthError.notStored
        }
        return OAuthAccess(accessToken: granted.accessToken, expiresIn: granted.expiresIn)
    }
}

public actor TokenManager {
    private let client: OAuthClient
    private let endpoint: URL
    private let tokens: any RefreshTokenStore
    private nonisolated let session: URLSession
    private var inflight: [String: Task<TokenGrant, Error>] = [:]
    private var joins: [String: Int] = [:]

    public init(client: OAuthClient, tokenEndpoint: URL, tokens: any RefreshTokenStore) {
        self.client = client
        self.endpoint = tokenEndpoint
        self.tokens = tokens
        self.session = OAuthHTTP.session()
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func refresh(session name: String) async throws -> OAuthAccess {
        if let task = inflight[name] {
            joins[name, default: 0] += 1
            let grant = try await task.value
            return OAuthAccess(accessToken: grant.accessToken, expiresIn: grant.expiresIn)
        }
        let task = Task { try await self.performRefresh(session: name) }
        inflight[name] = task
        joins[name] = 1
        let grant = try await task.value
        return OAuthAccess(accessToken: grant.accessToken, expiresIn: grant.expiresIn)
    }

    func refreshJoinCount(session name: String) -> Int {
        joins[name] ?? 0
    }

    private func performRefresh(session name: String) async throws -> TokenGrant {
        defer { inflight[name] = nil }
        guard let refresh = try await tokens.load(session: name), !refresh.isEmpty else {
            throw OAuthError.missingRefreshToken
        }
        let grant = try await OAuthHTTP.post(
            endpoint: endpoint,
            fields: [
                ("client_id", client.id),
                ("client_secret", client.secret),
                ("refresh_token", refresh),
                ("grant_type", "refresh_token"),
            ],
            session: session
        )
        if let rotated = grant.refreshToken, !rotated.isEmpty {
            try await tokens.store(session: name, refreshToken: rotated)
        }
        return grant
    }
}

private struct InstalledClientDocument: Decodable {
    struct Installed: Decodable {
        var clientId: String
        var clientSecret: String

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case clientSecret = "client_secret"
        }
    }

    var installed: Installed
}

private struct TokenGrant: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int?
}

private enum PKCE {
    static func verifier() -> String {
        encode(randomBytes(32))
    }

    static func state() -> String {
        encode(randomBytes(32))
    }

    static func challenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return encode(Data(digest))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            let key = SymmetricKey(size: .bits256)
            return key.withUnsafeBytes { Data($0) }
        }
        return Data(bytes)
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func authorizationURL(client: OAuthClient, redirect: String, state: String, challenge: String) throws -> URL {
    guard var components = URLComponents(url: OAuthDrive.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
        throw OAuthError.loopbackFailed
    }
    components.queryItems = [
        URLQueryItem(name: "client_id", value: client.id),
        URLQueryItem(name: "redirect_uri", value: redirect),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "scope", value: OAuthDrive.scope),
        URLQueryItem(name: "access_type", value: "offline"),
        URLQueryItem(name: "prompt", value: "consent"),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
    ]
    guard let url = components.url else {
        throw OAuthError.loopbackFailed
    }
    return url
}

private enum OAuthHTTP {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    static func post(endpoint: URL, fields: [(String, String)], session: URLSession) async throws -> TokenGrant {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.tokenRejected(-1)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.malformedTokenResponse
        }
        guard http.statusCode == 200 else {
            throw OAuthError.tokenRejected(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.malformedTokenResponse
        }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.malformedTokenResponse
        }
        let refresh = object["refresh_token"] as? String
        let expires = object["expires_in"] as? Int
        return TokenGrant(accessToken: access, refreshToken: refresh, expiresIn: expires)
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(percent(key))=\(percent(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func percent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private struct LoopbackCallback: Sendable {
    var code: String?
    var state: String?
    var error: String?
}

private final class LoopbackRedirect: @unchecked Sendable {
    let port: UInt16
    private let queue = DispatchQueue(label: "gcsf.oauth.loopback")
    private let lock = NSLock()
    private var listenFD: Int32
    private var continuation: CheckedContinuation<LoopbackCallback, Error>?
    private var pending: Result<LoopbackCallback, Error>?
    private var resumed = false
    private var stopped = false
    private var expiration: DispatchWorkItem?

    init(port requested: UInt16, timeout: Duration) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthError.loopbackFailed
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw OAuthError.loopbackFailed
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw OAuthError.loopbackFailed
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.getsockname(fd, raw, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw OAuthError.loopbackFailed
        }
        listenFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)
        let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
        let work = DispatchWorkItem { [weak self] in
            self?.expire()
        }
        expiration = work
        let captured = fd
        queue.async { [weak self] in
            self?.acceptOne(captured)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: work)
    }

    func nextCallback() async throws -> LoopbackCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending {
                let result = pending
                self.pending = nil
                resumed = true
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            if stopped {
                lock.unlock()
                continuation.resume(throwing: OAuthError.loopbackFailed)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func stop() {
        expiration?.cancel()
        lock.lock()
        let current = listenFD
        listenFD = -1
        stopped = true
        let waiter = continuation
        continuation = nil
        if waiter != nil {
            resumed = true
        }
        lock.unlock()
        if current >= 0 {
            Darwin.close(current)
        }
        waiter?.resume(throwing: OAuthError.loopbackFailed)
    }

    private func expire() {
        lock.lock()
        if resumed || pending != nil || stopped {
            lock.unlock()
            return
        }
        resumed = true
        let waiter = continuation
        continuation = nil
        let current = listenFD
        listenFD = -1
        stopped = true
        lock.unlock()
        expiration?.cancel()
        if current >= 0 {
            Darwin.close(current)
        }
        waiter?.resume(throwing: OAuthError.timedOut)
    }

    private func acceptOne(_ fd: Int32) {
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
            deliver(.failure(OAuthError.loopbackFailed))
            return
        }
        var nosig: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout.size(ofValue: nosig)))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let callback: LoopbackCallback
        do {
            callback = try readCallback(client)
        } catch {
            let body = "<!DOCTYPE html><html><body>Sign-in failed.</body></html>"
            writeResponse(client, status: 400, body: body)
            Darwin.close(client)
            deliver(.failure(OAuthError.loopbackFailed))
            return
        }
        deliver(.success(callback))
        let body = "<!DOCTYPE html><html><body>Signed in. You can close this window.</body></html>"
        writeResponse(client, status: 200, body: body)
        Darwin.close(client)
    }

    private func deliver(_ result: Result<LoopbackCallback, Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        if let continuation {
            resumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        pending = result
        lock.unlock()
    }

    private func readCallback(_ fd: Int32) throws -> LoopbackCallback {
        let (header, _) = try readHeaders(fd)
        guard let lineEnd = header.range(of: "\r\n") else {
            throw OAuthError.loopbackFailed
        }
        let start = header[..<lineEnd.lowerBound]
        let parts = start.split(separator: " ")
        guard parts.count >= 2 else {
            throw OAuthError.loopbackFailed
        }
        let target = String(parts[1])
        let absolute = target.hasPrefix("/") ? "http://127.0.0.1\(target)" : target
        guard let components = URLComponents(string: absolute) else {
            throw OAuthError.loopbackFailed
        }
        var code: String?
        var state: String?
        var error: String?
        for item in components.queryItems ?? [] {
            switch item.name {
            case "code" where code == nil:
                code = item.value
            case "state" where state == nil:
                state = item.value
            case "error" where error == nil:
                error = item.value
            default:
                continue
            }
        }
        return LoopbackCallback(code: code, state: state, error: error)
    }

    private func readHeaders(_ fd: Int32) throws -> (String, Data) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            if data.count > 65_536 {
                throw OAuthError.loopbackFailed
            }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count == 0 {
                throw OAuthError.loopbackFailed
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw OAuthError.loopbackFailed
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw OAuthError.loopbackFailed
        }
        let header = String(decoding: data.subdata(in: 0..<marker.lowerBound), as: UTF8.self)
        let rest = data.subdata(in: marker.upperBound..<data.count)
        return (header, rest)
    }

    private func writeResponse(_ fd: Int32, status: Int, body: String) {
        let payload = Data(body.utf8)
        let reason = status == 200 ? "OK" : "Bad Request"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nContent-Type: text/html; charset=utf-8\r\n\r\n"
        var bytes = Data(head.utf8)
        bytes.append(payload)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if wrote < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                if wrote == 0 {
                    return
                }
                sent += wrote
            }
        }
    }
}
