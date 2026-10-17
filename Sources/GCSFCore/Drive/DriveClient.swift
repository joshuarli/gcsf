import Foundation

public enum DriveClientError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case rateLimited
    case server(Int)
    case status(Int)
    case missingRootID
    case missingUploadLocation
    case malformedResponse(String)
}

public actor DriveClient: DriveBackend {
    public static let productionBaseURL = URL(string: "https://www.googleapis.com")!

    private static let fileFields = "id,name,mimeType,parents,size,headRevision,headRevisionId,md5Checksum,sha1Checksum,sha256Checksum,owners(emailAddress),webViewLink,trashed,createdTime,modifiedTime"

    private let baseURL: URL
    private nonisolated let session: URLSession
    private nonisolated let redirects: DriveRedirectDelegate
    private let refresh: @Sendable () async throws -> String
    private let extraRetries: Int
    private var token: String

    public init(
        baseURL: URL = DriveClient.productionBaseURL,
        bearerToken: String,
        extraRetries: Int = 3,
        refresh: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.refresh = refresh
        self.extraRetries = min(3, max(0, extraRetries))
        self.token = bearerToken
        let redirects = DriveRedirectDelegate(token: bearerToken)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        self.redirects = redirects
        self.session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func listFiles(query: String?, pageToken: String?, pageSize: Int?) async throws -> DriveFilePage {
        let fields = "nextPageToken,files(\(Self.fileFields))"
        var items = [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "corpora", value: "user"),
        ]
        if let query {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let pageSize {
            items.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
        }
        let target = try endpoint(path: "/drive/v3/files", query: items)
        let (response, data) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: target, method: "GET", token: token, body: nil)
        }
        _ = response
        return try decodePage(data)
    }

    public func getFile(id: DriveID) async throws -> DriveFile {
        let target = try endpoint(
            path: "/drive/v3/files/\(try escape(id.rawValue))",
            query: [URLQueryItem(name: "fields", value: Self.fileFields)]
        )
        let (_, data) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: target, method: "GET", token: token, body: nil)
        }
        return try decodeFile(data)
    }

    public func createFile(metadata: DriveFileCreate) async throws -> DriveFile {
        let target = try endpoint(
            path: "/drive/v3/files",
            query: [URLQueryItem(name: "fields", value: Self.fileFields)]
        )
        let body = try jsonData(createFields(metadata))
        let (_, data) = try await execute(acceptable: [200, 201]) { token in
            self.jsonRequest(url: target, method: "POST", token: token, body: body)
        }
        return try decodeFile(data)
    }

    public func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile {
        let target = try endpoint(
            path: "/drive/v3/files/\(try escape(id.rawValue))",
            query: [URLQueryItem(name: "fields", value: Self.fileFields)]
        )
        let body = try jsonData(updateFields(metadata))
        let (_, data) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: target, method: "PATCH", token: token, body: body)
        }
        return try decodeFile(data)
    }

    public func deleteFile(id: DriveID) async throws {
        let target = try endpoint(path: "/drive/v3/files/\(try escape(id.rawValue))", query: [])
        _ = try await execute(acceptable: [200, 204]) { token in
            self.jsonRequest(url: target, method: "DELETE", token: token, body: nil)
        }
    }

    public func exportFile(id: DriveID, mimeType: String) async throws -> Data {
        let target = try endpoint(
            path: "/drive/v3/files/\(try escape(id.rawValue))/export",
            query: [URLQueryItem(name: "mimeType", value: mimeType)]
        )
        let (_, data) = try await execute(acceptable: [200]) { token in
            var request = self.jsonRequest(url: target, method: "GET", token: token, body: nil)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            return request
        }
        return data
    }

    public func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent {
        let target = try endpoint(
            path: "/drive/v3/files/\(try escape(id.rawValue))",
            query: [URLQueryItem(name: "alt", value: "media")]
        )
        let (response, data) = try await execute(acceptable: [200, 206]) { token in
            var request = URLRequest(url: target)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if let range {
                request.setValue(try self.rangeHeader(range), forHTTPHeaderField: "Range")
            }
            return request
        } transport: { request in
            try await self.stream(request, range: range)
        }
        return content(from: response, body: data, requested: range)
    }

    public func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile {
        let path: String
        let method: String
        if let existing = intent.existingFileID {
            path = "/upload/drive/v3/files/\(try escape(existing.rawValue))"
            method = "PATCH"
        } else {
            path = "/upload/drive/v3/files"
            method = "POST"
        }
        let target = try endpoint(
            path: path,
            query: [
                URLQueryItem(name: "uploadType", value: "multipart"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        let payload = try multipartBody(intent)
        let (_, data) = try await execute(acceptable: [200, 201]) { token in
            var request = URLRequest(url: target)
            request.httpMethod = method
            request.timeoutInterval = 15
            request.httpBody = payload.body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/related; boundary=\(payload.boundary)", forHTTPHeaderField: "Content-Type")
            return request
        }
        return try decodeFile(data)
    }

    public func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession {
        let path: String
        let method: String
        if let existing = intent.existingFileID {
            path = "/upload/drive/v3/files/\(try escape(existing.rawValue))"
            method = "PATCH"
        } else {
            path = "/upload/drive/v3/files"
            method = "POST"
        }
        let target = try endpoint(
            path: path,
            query: [
                URLQueryItem(name: "uploadType", value: "resumable"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        let body = try jsonData(createFields(intent.metadata))
        let (response, _) = try await execute(acceptable: [200, 201]) { token in
            var request = self.jsonRequest(url: target, method: method, token: token, body: body)
            request.setValue(intent.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(intent.totalSize), forHTTPHeaderField: "X-Upload-Content-Length")
            return request
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let resolved = resolveLocation(location, base: target) else {
            throw DriveClientError.missingUploadLocation
        }
        return ResumableUploadSession(uri: resolved, committedOffset: 0)
    }

    public func resumeUpload(session: ResumableUploadSession, chunk: DriveUploadChunk) async throws -> ResumableUploadProgress {
        guard let target = URL(string: session.uri) else {
            throw DriveClientError.malformedResponse("session")
        }
        let contentRange = contentRangeHeader(chunk)
        let (response, data) = try await execute(acceptable: [200, 201, 308]) { token in
            var request = URLRequest(url: target)
            request.httpMethod = "PUT"
            request.timeoutInterval = 15
            request.httpBody = chunk.bytes
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(contentRange, forHTTPHeaderField: "Content-Range")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            return request
        }
        if response.statusCode == 308 {
            let offset = response.value(forHTTPHeaderField: "Range").flatMap(committedOffset(from:)) ?? session.committedOffset
            return ResumableUploadProgress(committedOffset: offset, completedFile: nil, indeterminate: false)
        }
        guard let file = try? decodeFile(data) else {
            return ResumableUploadProgress(committedOffset: session.committedOffset, completedFile: nil, indeterminate: true)
        }
        let advanced = chunk.offset + Int64(chunk.bytes.count)
        return ResumableUploadProgress(committedOffset: advanced, completedFile: file, indeterminate: false)
    }

    public func startPageToken() async throws -> String {
        let target = try endpoint(path: "/drive/v3/changes/startPageToken", query: [])
        let (_, data) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: target, method: "GET", token: token, body: nil)
        }
        let object = try jsonObject(data, context: "token")
        guard let token = object["startPageToken"] as? String, !token.isEmpty else {
            throw DriveClientError.malformedResponse("token")
        }
        return token
    }

    public func listChanges(pageToken: String, pageSize: Int?) async throws -> DriveChangePage {
        let fields = "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fileFields)))"
        var items = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "includeRemoved", value: "true"),
            URLQueryItem(name: "restrictToMyDrive", value: "true"),
        ]
        if let pageSize {
            items.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
        }
        let target = try endpoint(path: "/drive/v3/changes", query: items)
        let (_, data) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: target, method: "GET", token: token, body: nil)
        }
        return try decodeChanges(data)
    }

    public func about() async throws -> DriveAbout {
        let target = try endpoint(
            path: "/drive/v3/about",
            query: [URLQueryItem(name: "fields", value: "rootFolderId,user(emailAddress)")]
        )
        let (_, data) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: target, method: "GET", token: token, body: nil)
        }
        let object = try jsonObject(data, context: "about")
        let email = try userEmail(object["user"])
        if let root = try optionalString(object["rootFolderId"], context: "about"), !root.isEmpty {
            return DriveAbout(rootFolderID: DriveID(rawValue: root), userEmail: email)
        }
        let rootTarget = try endpoint(
            path: "/drive/v3/files/root",
            query: [URLQueryItem(name: "fields", value: "id")]
        )
        let (_, rootData) = try await execute(acceptable: [200]) { token in
            self.jsonRequest(url: rootTarget, method: "GET", token: token, body: nil)
        }
        let rootObject = try jsonObject(rootData, context: "root")
        guard let root = try optionalString(rootObject["id"], context: "root"), !root.isEmpty else {
            throw DriveClientError.missingRootID
        }
        return DriveAbout(rootFolderID: DriveID(rawValue: root), userEmail: email)
    }

    public func refreshCredential() async throws {
        let updated = try await refresh()
        token = updated
        redirects.setToken(updated)
    }

    private func execute(
        acceptable: Set<Int>,
        make: (String) throws -> URLRequest,
        transport: (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) async throws -> (HTTPURLResponse, Data) {
        var refreshes = 0
        var retriesLeft = extraRetries
        var retryIndex = 0
        while true {
            try Task.checkCancellation()
            let request = try make(token)
            let (response, data) = try await transport(request)
            let status = response.statusCode
            if acceptable.contains(status) {
                return (response, data)
            }
            if status == 401 {
                if refreshes >= 1 {
                    throw DriveClientError.unauthorized
                }
                refreshes += 1
                try await refreshCredential()
                continue
            }
            if status == 429 || (500..<600).contains(status) {
                if retriesLeft <= 0 {
                    throw mapStatus(status)
                }
                retriesLeft -= 1
                let delay = retryDelay(attempt: retryIndex, response: response)
                retryIndex += 1
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                continue
            }
            throw mapStatus(status)
        }
    }

    private func execute(
        acceptable: Set<Int>,
        make: (String) throws -> URLRequest
    ) async throws -> (HTTPURLResponse, Data) {
        try await execute(acceptable: acceptable, make: make) { request in
            try await self.send(request)
        }
    }

    private func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DriveClientError.malformedResponse("response")
            }
            return (http, data)
        } catch let error as DriveClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func stream(_ request: URLRequest, range: ByteRange?) async throws -> (HTTPURLResponse, Data) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriveClientError.malformedResponse("response")
        }
        let data = try await collect(bytes, status: http.statusCode, range: range)
        return (http, data)
    }

    private func collect(_ bytes: URLSession.AsyncBytes, status: Int, range: ByteRange?) async throws -> Data {
        let skip: Int
        let take: Int?
        if status == 200, let range {
            skip = try byteCount(range.offset)
            take = range.length
        } else if status == 206 {
            skip = 0
            take = range?.length
        } else {
            skip = 0
            take = 65_536
        }
        return try await readLimited(bytes, skip: skip, take: take)
    }

    private func readLimited(_ bytes: URLSession.AsyncBytes, skip: Int, take: Int?) async throws -> Data {
        var iterator = bytes.makeAsyncIterator()
        var remainingSkip = skip
        while remainingSkip > 0 {
            try Task.checkCancellation()
            do {
                guard try await iterator.next() != nil else { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            }
            remainingSkip -= 1
        }
        var data = Data()
        if let take {
            if take > 0 {
                data.reserveCapacity(min(take, 1024 * 1024))
            }
            while data.count < take {
                try Task.checkCancellation()
                let byte: UInt8?
                do {
                    byte = try await iterator.next()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                }
                guard let byte else { break }
                data.append(byte)
            }
            if data.count >= take {
                bytes.task.cancel()
            }
        } else {
            while true {
                try Task.checkCancellation()
                let byte: UInt8?
                do {
                    byte = try await iterator.next()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                }
                guard let byte else { break }
                data.append(byte)
            }
        }
        return data
    }

    private func content(from response: HTTPURLResponse, body: Data, requested: ByteRange?) -> DriveContent {
        if response.statusCode == 206 {
            if let parsed = parseContentRange(response.value(forHTTPHeaderField: "Content-Range")) {
                return DriveContent(bytes: body, offset: parsed.start, totalSize: parsed.total)
            }
            return DriveContent(bytes: body, offset: requested?.offset ?? 0, totalSize: nil)
        }
        let total = headerInt64(response, "Content-Length")
        if let requested {
            return DriveContent(bytes: body, offset: requested.offset, totalSize: total)
        }
        return DriveContent(bytes: body, offset: 0, totalSize: total ?? Int64(body.count))
    }

    private func jsonRequest(url: URL, method: String, token: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func endpoint(path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DriveClientError.malformedResponse("base")
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw DriveClientError.malformedResponse("url")
        }
        return url
    }

    private func escape(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw DriveClientError.malformedResponse("url")
        }
        return escaped
    }

    private func rangeHeader(_ range: ByteRange) throws -> String {
        if let length = range.length {
            if length <= 0 {
                return "bytes=\(range.offset)-\(range.offset)"
            }
            let end = try add(range.offset, Int64(length) - 1)
            return "bytes=\(range.offset)-\(end)"
        }
        return "bytes=\(range.offset)-"
    }

    private func contentRangeHeader(_ chunk: DriveUploadChunk) -> String {
        let count = Int64(chunk.bytes.count)
        if count == 0 {
            let total = chunk.isLast ? String(chunk.offset) : "*"
            return "bytes */\(total)"
        }
        let end = chunk.offset + count - 1
        let total = chunk.isLast ? String(chunk.offset + count) : "*"
        return "bytes \(chunk.offset)-\(end)/\(total)"
    }

    private func committedOffset(from header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if let equals = trimmed.firstIndex(of: "=") {
            payload = String(trimmed[trimmed.index(after: equals)...])
        } else if let space = trimmed.firstIndex(of: " ") {
            payload = String(trimmed[trimmed.index(after: space)...])
        } else {
            payload = trimmed
        }
        guard let first = payload.split(separator: ",").first else { return nil }
        let bounds = first.split(separator: "-")
        guard bounds.count == 2 else { return nil }
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)
        guard let end = Int64(endText) else { return nil }
        return end + 1
    }

    private func parseContentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: Substring
        if trimmed.lowercased().hasPrefix("bytes ") {
            payload = trimmed.dropFirst(6)
        } else if trimmed.lowercased().hasPrefix("bytes=") {
            payload = trimmed.dropFirst(6)
        } else {
            return nil
        }
        let pieces = payload.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let bounds = pieces.first else { return nil }
        let ends = bounds.split(separator: "-")
        guard ends.count == 2, let start = Int64(ends[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let total: Int64?
        if pieces.count == 2 {
            let raw = pieces[1].trimmingCharacters(in: .whitespaces)
            total = raw == "*" ? nil : Int64(raw)
        } else {
            total = nil
        }
        return (start, total)
    }

    private func resolveLocation(_ value: String, base: URL) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        guard url.scheme != nil, url.host != nil else { return nil }
        return url.absoluteString
    }

    private func createFields(_ metadata: DriveFileCreate) -> [String: Any] {
        [
            "name": metadata.name,
            "mimeType": metadata.mimeType,
            "parents": metadata.parents.map(\.rawValue),
        ]
    }

    private func updateFields(_ metadata: DriveFileUpdate) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let name = metadata.name {
            fields["name"] = name
        }
        if let mimeType = metadata.mimeType {
            fields["mimeType"] = mimeType
        }
        if let parents = metadata.parents {
            fields["parents"] = parents.map(\.rawValue)
        }
        if let trashed = metadata.trashed {
            fields["trashed"] = trashed
        }
        return fields
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DriveClientError.malformedResponse("json")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func multipartBody(_ intent: MultipartUploadIntent) throws -> (boundary: String, body: Data) {
        let encoded = try jsonData(createFields(intent.metadata))
        var boundary = "gcsf_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let payload = encoded + intent.body
        if payload.range(of: Data(boundary.utf8)) != nil {
            boundary += "_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        }
        var body = Data()
        body.append(utf8("--\(boundary)\r\n"))
        body.append(utf8("Content-Type: application/json; charset=UTF-8\r\n\r\n"))
        body.append(encoded)
        body.append(utf8("\r\n--\(boundary)\r\n"))
        body.append(utf8("Content-Type: \(intent.mimeType)\r\n\r\n"))
        body.append(intent.body)
        body.append(utf8("\r\n--\(boundary)--\r\n"))
        return (boundary, body)
    }

    private func utf8(_ value: String) -> Data {
        Data(value.utf8)
    }

    private func decodePage(_ data: Data) throws -> DriveFilePage {
        let object = try jsonObject(data, context: "list")
        let filesValue = object["files"]
        let files: [DriveFile]
        if filesValue == nil || filesValue is NSNull {
            files = []
        } else {
            let rows = try objectArray(filesValue, context: "list")
            files = try rows.map { try decodeFileObject($0) }
        }
        let token = try optionalString(object["nextPageToken"], context: "list")
        return DriveFilePage(files: files, nextPageToken: token)
    }

    private func decodeChanges(_ data: Data) throws -> DriveChangePage {
        let object = try jsonObject(data, context: "changes")
        let rows: [[String: Any]]
        if object["changes"] == nil || object["changes"] is NSNull {
            rows = []
        } else {
            rows = try objectArray(object["changes"], context: "changes")
        }
        var changes: [DriveChange] = []
        changes.reserveCapacity(rows.count)
        for row in rows {
            let removed = try optionalBool(row["removed"], context: "changes") ?? false
            let file = try nestedFile(row["file"])
            let fileID = try optionalString(row["fileId"], context: "changes") ?? file?.id.rawValue
            guard let fileID, !fileID.isEmpty else {
                throw DriveClientError.malformedResponse("changes")
            }
            changes.append(DriveChange(fileID: DriveID(rawValue: fileID), removed: removed, file: file))
        }
        let next = try optionalString(object["nextPageToken"], context: "changes")
        let start = try optionalString(object["newStartPageToken"], context: "changes")
        return DriveChangePage(changes: changes, nextPageToken: next, newStartPageToken: start)
    }

    private func decodeFile(_ data: Data) throws -> DriveFile {
        try decodeFileObject(try jsonObject(data, context: "file"))
    }

    private func nestedFile(_ value: Any?) throws -> DriveFile? {
        if value == nil || value is NSNull {
            return nil
        }
        guard let object = value as? [String: Any] else {
            throw DriveClientError.malformedResponse("file")
        }
        return try decodeFileObject(object)
    }

    private func decodeFileObject(_ object: [String: Any]) throws -> DriveFile {
        guard let id = try optionalString(object["id"], context: "file"), !id.isEmpty else {
            throw DriveClientError.malformedResponse("file")
        }
        guard let name = try optionalString(object["name"], context: "file") else {
            throw DriveClientError.malformedResponse("file")
        }
        guard let mimeType = try optionalString(object["mimeType"], context: "file") else {
            throw DriveClientError.malformedResponse("file")
        }
        let parents = try stringArray(object["parents"], context: "file") ?? []
        let size = try optionalInt64(object["size"], context: "size")
        let revision = try optionalString(object["headRevision"], context: "file")
            ?? (try optionalString(object["headRevisionId"], context: "file"))
            ?? stringIfPresent(object["version"])
        let md5 = try optionalString(object["md5Checksum"], context: "file")
        let sha1 = try optionalString(object["sha1Checksum"], context: "file")
        let sha256 = try optionalString(object["sha256Checksum"], context: "file")
        let owner = try ownerEmails(object["owners"])
        let link = try optionalString(object["webViewLink"], context: "file")
        let trashed = try optionalBool(object["trashed"], context: "file") ?? false
        let created = try optionalDate(object["createdTime"], context: "createdTime")
        let modified = try optionalDate(object["modifiedTime"], context: "modifiedTime")
        return DriveFile(
            id: DriveID(rawValue: id),
            name: name,
            mimeType: mimeType,
            parents: parents.map { DriveID(rawValue: $0) },
            size: size,
            headRevision: revision,
            md5: md5,
            sha1: sha1,
            sha256: sha256,
            owner: owner,
            webViewLink: link,
            trashed: trashed,
            created: created,
            modified: modified
        )
    }

    private func userEmail(_ value: Any?) throws -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        guard let object = value as? [String: Any] else {
            throw DriveClientError.malformedResponse("about")
        }
        return try optionalString(object["emailAddress"], context: "about")
    }

    private func ownerEmails(_ value: Any?) throws -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        let rows = try objectArray(value, context: "file")
        var emails: [String] = []
        for row in rows {
            if let email = try optionalString(row["emailAddress"], context: "file"), !email.isEmpty {
                emails.append(email)
            }
        }
        if emails.isEmpty {
            return nil
        }
        return emails.joined(separator: ",")
    }

    private func jsonObject(_ data: Data, context: String) throws -> [String: Any] {
        if data.isEmpty {
            throw DriveClientError.malformedResponse(context)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DriveClientError.malformedResponse(context)
        }
        guard let dictionary = object as? [String: Any] else {
            throw DriveClientError.malformedResponse(context)
        }
        return dictionary
    }

    private func objectArray(_ value: Any?, context: String) throws -> [[String: Any]] {
        guard let value, !(value is NSNull) else {
            throw DriveClientError.malformedResponse(context)
        }
        guard let rows = value as? [Any] else {
            throw DriveClientError.malformedResponse(context)
        }
        var objects: [[String: Any]] = []
        objects.reserveCapacity(rows.count)
        for row in rows {
            guard let object = row as? [String: Any] else {
                throw DriveClientError.malformedResponse(context)
            }
            objects.append(object)
        }
        return objects
    }

    private func optionalString(_ value: Any?, context: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            throw DriveClientError.malformedResponse(context)
        }
        return string
    }

    private func stringIfPresent(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), !(value is NSNumber) else { return nil }
        return value as? String
    }

    private func stringArray(_ value: Any?, context: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rows = value as? [Any] else {
            throw DriveClientError.malformedResponse(context)
        }
        var strings: [String] = []
        strings.reserveCapacity(rows.count)
        for row in rows {
            guard let string = row as? String else {
                throw DriveClientError.malformedResponse(context)
            }
            strings.append(string)
        }
        return strings
    }

    private func optionalBool(_ value: Any?, context: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if isJSONBool(value) {
            return (value as? NSNumber)?.boolValue
        }
        throw DriveClientError.malformedResponse(context)
    }

    private func optionalInt64(_ value: Any?, context: String) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            guard let parsed = Int64(string) else {
                throw DriveClientError.malformedResponse(context)
            }
            return parsed
        }
        if isJSONBool(value) {
            throw DriveClientError.malformedResponse(context)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        throw DriveClientError.malformedResponse(context)
    }

    private func optionalDate(_ value: Any?, context: String) throws -> Date? {
        guard let raw = try optionalString(value, context: context) else { return nil }
        guard let date = parseDriveDate(raw) else {
            throw DriveClientError.malformedResponse(context)
        }
        return date
    }

    private func headerInt64(_ response: HTTPURLResponse, _ name: String) -> Int64? {
        guard let raw = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces),
              let value = Int64(raw) else {
            return nil
        }
        return value
    }

    private func byteCount(_ value: Int64) throws -> Int {
        guard value >= 0, value <= Int64(Int.max) else {
            throw DriveClientError.malformedResponse("range")
        }
        return Int(value)
    }

    private func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow else {
            throw DriveClientError.malformedResponse("range")
        }
        return sum.partialValue
    }

    private func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func mapStatus(_ status: Int) -> DriveClientError {
        switch status {
        case 401:
            .unauthorized
        case 403:
            .forbidden
        case 404:
            .notFound
        case 409:
            .conflict
        case 429:
            .rateLimited
        case 500..<600:
            .server(status)
        default:
            .status(status)
        }
    }

    private func retryDelay(attempt: Int, response: HTTPURLResponse) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(trimmed), seconds.isFinite {
                return max(0, seconds)
            }
            if let date = httpDate(trimmed) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        let exponential = min(pow(2.0, Double(attempt)), 8)
        return Double.random(in: 0...exponential)
    }

    private func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }

    private func parseDriveDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }
}

final class DriveRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String

    init(token: String) {
        self.token = token
    }

    func setToken(_ token: String) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    private func bearer() -> String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if response.statusCode == 308 {
            completionHandler(nil)
            return
        }
        var redirected = request
        let origin = task.originalRequest?.url
        let destination = request.url
        if let origin, let destination, sameOrigin(origin, destination) {
            redirected.setValue("Bearer \(bearer())", forHTTPHeaderField: "Authorization")
        } else {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }

    private func port(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
