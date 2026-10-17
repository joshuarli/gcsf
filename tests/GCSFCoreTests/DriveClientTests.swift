import Darwin
import Foundation
import Testing

@testable import GCSFCore

private let fileFieldMask = "id,name,mimeType,parents,size,headRevision,headRevisionId,md5Checksum,sha1Checksum,sha256Checksum,owners(emailAddress),webViewLink,trashed,createdTime,modifiedTime"

struct DriveClientTests {
    @Test func paginationReturnsOnePageUntilTheCallerPassesTheToken() async throws {
        let recorder = RequestLog()
        let server = try FixtureServer { request in
            recorder.add(request)
            if request.query["pageToken"] == nil {
                return FixtureResponse(status: 200, body: pageBody(token: "next"))
            }
            return FixtureResponse(status: 200, body: pageBody(token: nil))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let first = try await client.listFiles(query: "name = 'Notes'", pageToken: nil, pageSize: 2)
        #expect(recorder.count == 1)
        let opened = try #require(recorder.all().first)
        #expect(opened.method == "GET")
        #expect(opened.path == "/drive/v3/files")
        #expect(opened.query["q"] == "name = 'Notes'")
        #expect(opened.query["pageSize"] == "2")
        #expect(opened.query["pageToken"] == nil)
        #expect(opened.query["fields"] == "nextPageToken,files(\(fileFieldMask))")
        #expect(opened.headers["authorization"] == "Bearer secret")
        #expect(first.nextPageToken == "next")
        let file = try #require(first.files.first)
        #expect(first.files.count == 1)
        #expect(file == sampleFile(headRevision: "rev-head"))
        let second = try await client.listFiles(query: "name = 'Notes'", pageToken: "next", pageSize: 2)
        #expect(recorder.count == 2)
        #expect(recorder.all()[1].query["pageToken"] == "next")
        #expect(second.nextPageToken == nil)
        #expect(second.files.isEmpty)
    }

    @Test func unauthorizedRefreshesOnceThenSucceeds() async throws {
        let recorder = RequestLog()
        let refreshes = Counter()
        let server = try FixtureServer { request in
            recorder.add(request)
            if recorder.count == 1 {
                return FixtureResponse(status: 401)
            }
            return FixtureResponse(status: 200, body: fileData())
        }
        defer { server.stop() }
        let client = DriveClient(
            baseURL: localhost(server.port),
            bearerToken: "stale",
            extraRetries: 0,
            refresh: {
                refreshes.increment()
                return "fresh"
            }
        )
        let file = try await client.getFile(id: DriveID(rawValue: "file-1"))
        #expect(file.id == DriveID(rawValue: "file-1"))
        #expect(refreshes.value == 1)
        let requests = recorder.all()
        #expect(requests.count == 2)
        #expect(requests[0].headers["authorization"] == "Bearer stale")
        #expect(requests[1].headers["authorization"] == "Bearer fresh")
        #expect(requests[0].query["fields"] == fileFieldMask)
    }

    @Test func secondUnauthorizedDoesNotRefreshAgain() async throws {
        let recorder = RequestLog()
        let refreshes = Counter()
        let server = try FixtureServer { request in
            recorder.add(request)
            return FixtureResponse(status: 401)
        }
        defer { server.stop() }
        let client = DriveClient(
            baseURL: localhost(server.port),
            bearerToken: "stale",
            extraRetries: 3,
            refresh: {
                refreshes.increment()
                return "fresh"
            }
        )
        await #expect(throws: DriveClientError.unauthorized) {
            try await client.getFile(id: DriveID(rawValue: "file-1"))
        }
        #expect(refreshes.value == 1)
        #expect(recorder.count == 2)
        #expect(recorder.all().map { $0.headers["authorization"] } == ["Bearer stale", "Bearer fresh"])
    }

    @Test func resumable308RecoversCommittedOffset() async throws {
        let recorder = RequestLog()
        let server = try FixtureServer { request in
            recorder.add(request)
            if request.method != "PUT" {
                return FixtureResponse(status: 500)
            }
            let location = "http://127.0.0.1:\(request.port)/followed"
            return FixtureResponse(status: 308, headers: [("Range", "bytes=0-4"), ("Location", location)])
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let session = ResumableUploadSession(uri: "http://127.0.0.1:\(server.port)/upload/session", committedOffset: 0)
        let chunk = DriveUploadChunk(offset: 0, bytes: Data("abcde".utf8), isLast: false)
        let progress = try await client.resumeUpload(session: session, chunk: chunk)
        let request = try #require(recorder.all().first)
        #expect(request.method == "PUT")
        #expect(request.path == "/upload/session")
        #expect(request.headers["content-range"] == "bytes 0-4/*")
        #expect(request.body == Data("abcde".utf8))
        #expect(progress.committedOffset == 5)
        #expect(progress.completedFile == nil)
        #expect(progress.indeterminate == false)
        #expect(recorder.count == 1)
    }

    @Test func resumableEmptyOrTruncatedBodyIsIndeterminate() async throws {
        let bodies = [Data(), Data("{".utf8)]
        for body in bodies {
            let server = try FixtureServer { _ in
                FixtureResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
            }
            defer { server.stop() }
            let client = makeClient(port: server.port, extraRetries: 0)
            let session = ResumableUploadSession(uri: "http://127.0.0.1:\(server.port)/upload/session", committedOffset: 4)
            let chunk = DriveUploadChunk(offset: 4, bytes: Data("xy".utf8), isLast: true)
            let progress = try await client.resumeUpload(session: session, chunk: chunk)
            #expect(progress.indeterminate == true)
            #expect(progress.completedFile == nil)
            #expect(progress.committedOffset == 4)
        }
        let server = try FixtureServer { _ in
            FixtureResponse(status: 200, body: fileData(name: "done"))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let session = ResumableUploadSession(uri: "http://127.0.0.1:\(server.port)/upload/session", committedOffset: 0)
        let chunk = DriveUploadChunk(offset: 0, bytes: Data("xy".utf8), isLast: true)
        let progress = try await client.resumeUpload(session: session, chunk: chunk)
        #expect(progress.indeterminate == false)
        #expect(progress.completedFile?.name == "done")
        #expect(progress.committedOffset == 2)
    }

    @Test func crossOriginRedirectDropsTheBearerAndSameOriginKeepsIt() async throws {
        let landed = RequestLog()
        let second = try FixtureServer { request in
            landed.add(request)
            return FixtureResponse(status: 200, body: fileData(id: "landed"))
        }
        defer { second.stop() }
        let originLog = RequestLog()
        let origin = try FixtureServer { request in
            originLog.add(request)
            if request.path == "/drive/v3/files/origin" {
                let location = "http://127.0.0.1:\(second.port)/drive/v3/files/landed"
                return FixtureResponse(status: 302, headers: [("Location", location)])
            }
            return FixtureResponse(status: 500)
        }
        defer { origin.stop() }
        let client = makeClient(port: origin.port, extraRetries: 0)
        let file = try await client.getFile(id: DriveID(rawValue: "origin"))
        #expect(file.id == DriveID(rawValue: "landed"))
        #expect(originLog.all().first?.headers["authorization"] == "Bearer secret")
        #expect(landed.all().first?.headers["authorization"] == nil)
        #expect(landed.count == 1)

        let sameLog = RequestLog()
        let same = try FixtureServer { request in
            sameLog.add(request)
            if request.path == "/drive/v3/files/origin" {
                let location = "http://127.0.0.1:\(request.port)/drive/v3/files/landed"
                return FixtureResponse(status: 302, headers: [("Location", location)])
            }
            return FixtureResponse(status: 200, body: fileData(id: "kept"))
        }
        defer { same.stop() }
        let sameClient = makeClient(port: same.port, extraRetries: 0)
        let kept = try await sameClient.getFile(id: DriveID(rawValue: "origin"))
        #expect(kept.id == DriveID(rawValue: "kept"))
        let hops = sameLog.all()
        #expect(hops.count == 2)
        #expect(hops[0].headers["authorization"] == "Bearer secret")
        #expect(hops[1].path == "/drive/v3/files/landed")
        #expect(hops[1].headers["authorization"] == "Bearer secret")
    }

    @Test func retryHonorsRetryAfterWithTheTestRetryBound() async throws {
        let bounded = RequestLog()
        let boundedServer = try FixtureServer { request in
            bounded.add(request)
            return FixtureResponse(status: 429, headers: [("Retry-After", "5")])
        }
        defer { boundedServer.stop() }
        let boundedClient = makeClient(port: boundedServer.port, extraRetries: 0)
        let started = ContinuousClock.now
        await #expect(throws: DriveClientError.rateLimited) {
            try await boundedClient.listFiles(query: nil, pageToken: nil, pageSize: nil)
        }
        #expect(started.duration(to: .now) < .milliseconds(700))
        #expect(bounded.count == 1)

        let fast = RequestLog()
        let fastMarks = Marks()
        let fastServer = try FixtureServer { request in
            fast.add(request)
            fastMarks.add(ContinuousClock.now)
            if fast.count == 1 {
                return FixtureResponse(status: 429, headers: [("Retry-After", "0")])
            }
            return FixtureResponse(status: 200, body: pageBody(token: nil))
        }
        defer { fastServer.stop() }
        let fastClient = makeClient(port: fastServer.port, extraRetries: 1)
        _ = try await fastClient.listFiles(query: nil, pageToken: nil, pageSize: 1)
        let fastMarksAll = fastMarks.all()
        #expect(fast.count == 2)
        #expect(fastMarksAll[0].duration(to: fastMarksAll[1]) < .milliseconds(700))

        let delayed = RequestLog()
        let delayedMarks = Marks()
        let delayedServer = try FixtureServer { request in
            delayed.add(request)
            delayedMarks.add(ContinuousClock.now)
            if delayed.count == 1 {
                return FixtureResponse(status: 503, headers: [("Retry-After", "1")])
            }
            return FixtureResponse(status: 200, body: pageBody(token: nil))
        }
        defer { delayedServer.stop() }
        let delayedClient = makeClient(port: delayedServer.port, extraRetries: 1)
        _ = try await delayedClient.listFiles(query: nil, pageToken: nil, pageSize: 1)
        let delayedAll = delayedMarks.all()
        #expect(delayed.count == 2)
        #expect(delayedAll[0].duration(to: delayedAll[1]) >= .milliseconds(900))
        #expect(delayedAll[0].duration(to: delayedAll[1]) < .seconds(3))
    }

    @Test func forbiddenNotFoundConflictAndServerAreDistinct() async throws {
        let cases: [(Int, DriveClientError)] = [
            (403, .forbidden),
            (404, .notFound),
            (409, .conflict),
            (503, .server(503)),
            (429, .rateLimited),
        ]
        for item in cases {
            let server = try FixtureServer { _ in FixtureResponse(status: item.0) }
            defer { server.stop() }
            let client = makeClient(port: server.port, extraRetries: 0)
            await #expect(throws: item.1) {
                try await client.getFile(id: DriveID(rawValue: "a"))
            }
        }
    }

    @Test func cancellationDuringRetryThrowsAndDoesNotRetry() async throws {
        let recorder = RequestLog()
        let server = try FixtureServer { request in
            recorder.add(request)
            return FixtureResponse(status: 429, headers: [("Retry-After", "5")])
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 1)
        let task = Task {
            try await client.listFiles(query: nil, pageToken: nil, pageSize: nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while recorder.count == 0 {
            if ContinuousClock.now > deadline {
                task.cancel()
                Issue.record("request was not received")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.result
        switch outcome {
        case .success:
            Issue.record("expected cancellation")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.count == 1)
    }

    @Test func downloadSendsRangeAndDoesNotKeepBytesPastTheRequestedLength() async throws {
        let recorder = RequestLog()
        let server = try FixtureServer { request in
            recorder.add(request)
            if request.headers["range"] == "bytes=4-6" {
                return FixtureResponse(
                    status: 206,
                    headers: [("Content-Range", "bytes 4-6/10")],
                    body: Data("xyz".utf8)
                )
            }
            return FixtureResponse(status: 200, body: Data("abcdefghij".utf8))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let partial = try await client.downloadContent(id: DriveID(rawValue: "file-1"), range: ByteRange(offset: 4, length: 3))
        #expect(partial.bytes == Data("xyz".utf8))
        #expect(partial.offset == 4)
        #expect(partial.totalSize == 10)
        let whole = try await client.downloadContent(id: DriveID(rawValue: "file-1"), range: nil)
        #expect(whole.bytes == Data("abcdefghij".utf8))
        #expect(whole.offset == 0)
        #expect(whole.totalSize == 10)
        let capped = try await client.downloadContent(id: DriveID(rawValue: "file-1"), range: ByteRange(offset: 1, length: 2))
        #expect(capped.bytes == Data("bc".utf8))
        #expect(capped.bytes.count == 2)
        #expect(capped.offset == 1)
        #expect(capped.totalSize == 10)
        #expect(recorder.all().map { $0.headers["range"] } == ["bytes=4-6", nil, "bytes=1-2"])
    }

    @Test func aboutMapsRootIDAndUserEmail() async throws {
        let recorder = RequestLog()
        let server = try FixtureServer { request in
            recorder.add(request)
            let body = Data("{\"rootFolderId\":\"root-1\",\"user\":{\"emailAddress\":\"u@example.com\"}}".utf8)
            return FixtureResponse(status: 200, body: body)
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let about = try await client.about()
        #expect(about == DriveAbout(rootFolderID: DriveID(rawValue: "root-1"), userEmail: "u@example.com"))
        #expect(recorder.all().first?.path == "/drive/v3/about")
        #expect(recorder.all().first?.query["fields"] == "rootFolderId,user(emailAddress)")
    }

    @Test func aboutMissingRootUsesADedicatedRequest() async throws {
        let server = try FixtureServer { request in
            #expect(request.path == "/drive/v3/about")
            return FixtureResponse(status: 200, body: Data("{\"user\":{\"emailAddress\":\"u@example.com\"}}".utf8))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        await #expect(throws: DriveClientError.missingRootID) {
            try await client.about()
        }
    }

    @Test func getFileMapsVersionFixtureAliasOntoHeadRevision() async throws {
        let server = try FixtureServer { _ in
            FixtureResponse(status: 200, body: fileData(headRevision: nil, headRevisionId: nil, version: "fixture-alias"))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let file = try await client.getFile(id: DriveID(rawValue: "file-1"))
        #expect(file.headRevision == "fixture-alias")
    }

    @Test func getFileMapsHeadRevisionIdWhenHeadRevisionIsAbsent() async throws {
        let server = try FixtureServer { _ in
            FixtureResponse(
                status: 200,
                body: fileData(size: .number(9), headRevision: nil, headRevisionId: "head-id", numericVersion: 12)
            )
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let file = try await client.getFile(id: DriveID(rawValue: "file-1"))
        #expect(file.headRevision == "head-id")
        #expect(file.size == 9)
    }

    @Test func metadataCreateUpdateDeleteExportAndMultipartUseDrivePaths() async throws {
        let recorder = RequestLog()
        let server = try FixtureServer { request in
            recorder.add(request)
            if request.method == "DELETE" {
                return FixtureResponse(status: 404)
            }
            if request.path.hasSuffix("/export") {
                return FixtureResponse(status: 200, body: Data("exported".utf8))
            }
            if request.query["uploadType"] == "resumable" {
                let location = "http://127.0.0.1:\(request.port)/upload/session/new"
                return FixtureResponse(status: 200, headers: [("Location", location)])
            }
            return FixtureResponse(status: 200, body: fileData(name: "saved"))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let created = try await client.createFile(
            metadata: DriveFileCreate(name: "Notes", mimeType: "text/plain", parents: [DriveID(rawValue: "root")])
        )
        #expect(created.name == "saved")
        let create = recorder.all()[0]
        #expect(create.method == "POST")
        #expect(create.path == "/drive/v3/files")
        #expect(create.query["uploadType"] == nil)
        let createJSON = try #require(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect(createJSON["name"] as? String == "Notes")
        #expect(createJSON["mimeType"] as? String == "text/plain")
        #expect(createJSON["parents"] as? [String] == ["root"])
        #expect(createJSON.count == 3)

        _ = try await client.updateFile(
            id: DriveID(rawValue: "file-1"),
            metadata: DriveFileUpdate(name: "Renamed", mimeType: nil, parents: nil, trashed: true)
        )
        let update = recorder.all()[1]
        #expect(update.method == "PATCH")
        #expect(update.path == "/drive/v3/files/file-1")
        let updateJSON = try #require(JSONSerialization.jsonObject(with: update.body) as? [String: Any])
        #expect(updateJSON["name"] as? String == "Renamed")
        #expect(updateJSON["trashed"] as? Bool == true)
        #expect(updateJSON["mimeType"] == nil)
        #expect(updateJSON["parents"] == nil)
        #expect(Set(updateJSON.keys) == Set(["name", "trashed"]))

        await #expect(throws: DriveClientError.notFound) {
            try await client.deleteFile(id: DriveID(rawValue: "missing"))
        }
        #expect(recorder.all()[2].method == "DELETE")
        #expect(recorder.all()[2].path == "/drive/v3/files/missing")

        let exported = try await client.exportFile(id: DriveID(rawValue: "file-1"), mimeType: "text/plain")
        #expect(exported == Data("exported".utf8))
        #expect(recorder.all()[3].path == "/drive/v3/files/file-1/export")
        #expect(recorder.all()[3].query["mimeType"] == "text/plain")

        _ = try await client.multipartUpload(
            MultipartUploadIntent(
                existingFileID: nil,
                metadata: DriveFileCreate(name: "Blob", mimeType: "text/plain", parents: [DriveID(rawValue: "root")]),
                mimeType: "text/plain",
                body: Data("xyz".utf8)
            )
        )
        let multipart = recorder.all()[4]
        #expect(multipart.method == "POST")
        #expect(multipart.path == "/upload/drive/v3/files")
        #expect(multipart.query["uploadType"] == "multipart")
        #expect(multipart.body.range(of: Data("xyz".utf8)) != nil)
        #expect(String(decoding: multipart.body, as: UTF8.self).contains("\"name\":\"Blob\""))

        _ = try await client.multipartUpload(
            MultipartUploadIntent(
                existingFileID: DriveID(rawValue: "file-1"),
                metadata: DriveFileCreate(name: "Blob", mimeType: "text/plain", parents: []),
                mimeType: "application/octet-stream",
                body: Data("q".utf8)
            )
        )
        let patch = recorder.all()[5]
        #expect(patch.method == "PATCH")
        #expect(patch.path == "/upload/drive/v3/files/file-1")

        _ = try await client.startResumableUpload(
            ResumableUploadIntent(
                existingFileID: nil,
                metadata: DriveFileCreate(name: "Big", mimeType: "text/plain", parents: [DriveID(rawValue: "root")]),
                mimeType: "text/plain",
                totalSize: 12
            )
        )
        let start = recorder.all()[6]
        #expect(start.method == "POST")
        #expect(start.path == "/upload/drive/v3/files")
        #expect(start.query["uploadType"] == "resumable")
        #expect(start.headers["x-upload-content-type"] == "text/plain")
        #expect(start.headers["x-upload-content-length"] == "12")
    }

    @Test func startResumableUploadReadsTheLocationAndChangesListOnePage() async throws {
        let server = try FixtureServer { request in
            if request.path == "/upload/drive/v3/files" {
                let location = "http://127.0.0.1:\(request.port)/upload/session/abc"
                return FixtureResponse(status: 200, headers: [("Location", location)])
            }
            if request.path == "/drive/v3/changes/startPageToken" {
                return FixtureResponse(status: 200, body: Data("{\"startPageToken\":\"start-1\"}".utf8))
            }
            let body = """
            {"changes":[{"fileId":"file-1","removed":false,"file":\(fileJSON())},{"fileId":"gone","removed":true}],"newStartPageToken":"start-2"}
            """
            return FixtureResponse(status: 200, body: Data(body.utf8))
        }
        defer { server.stop() }
        let client = makeClient(port: server.port, extraRetries: 0)
        let session = try await client.startResumableUpload(
            ResumableUploadIntent(
                existingFileID: nil,
                metadata: DriveFileCreate(name: "Big", mimeType: "text/plain", parents: []),
                mimeType: "text/plain",
                totalSize: 3
            )
        )
        #expect(session.uri == "http://127.0.0.1:\(server.port)/upload/session/abc")
        #expect(session.committedOffset == 0)
        let token = try await client.startPageToken()
        #expect(token == "start-1")
        let page = try await client.listChanges(pageToken: token, pageSize: 10)
        #expect(page.newStartPageToken == "start-2")
        #expect(page.nextPageToken == nil)
        #expect(page.changes.count == 2)
        #expect(page.changes[0].file?.name == "Notes")
        #expect(page.changes[1] == DriveChange(fileID: DriveID(rawValue: "gone"), removed: true, file: nil))
    }

    @Test func refreshCredentialUsesTheSameClosureAsUnauthorized() async throws {
        let recorder = RequestLog()
        let refreshes = Counter()
        let server = try FixtureServer { request in
            recorder.add(request)
            return FixtureResponse(status: 200, body: fileData())
        }
        defer { server.stop() }
        let client = DriveClient(
            baseURL: localhost(server.port),
            bearerToken: "stale",
            extraRetries: 0,
            refresh: {
                refreshes.increment()
                return "rotated"
            }
        )
        try await client.refreshCredential()
        _ = try await client.getFile(id: DriveID(rawValue: "file-1"))
        #expect(refreshes.value == 1)
        #expect(recorder.all().first?.headers["authorization"] == "Bearer rotated")
    }
}

private func makeClient(port: UInt16, extraRetries: Int) -> DriveClient {
    DriveClient(
        baseURL: localhost(port),
        bearerToken: "secret",
        extraRetries: extraRetries,
        refresh: { "rotated" }
    )
}

private func localhost(_ port: UInt16) -> URL {
    URL(string: "http://127.0.0.1:\(port)")!
}

private enum JSONSize {
    case text(String)
    case number(Int)
}

private func pageBody(token: String?) -> Data {
    var object: [String: Any] = ["files": token == nil ? [] : [fileObject()]]
    if let token {
        object["nextPageToken"] = token
    }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func fileData(
    id: String = "file-1",
    name: String = "Notes",
    size: JSONSize = .text("12"),
    headRevision: String? = "rev-head",
    headRevisionId: String? = "rev-id",
    version: String? = nil,
    numericVersion: Int? = nil
) -> Data {
    try! JSONSerialization.data(withJSONObject: fileObject(
        id: id,
        name: name,
        size: size,
        headRevision: headRevision,
        headRevisionId: headRevisionId,
        version: version,
        numericVersion: numericVersion
    ))
}

private func fileJSON() -> String {
    String(decoding: fileData(headRevision: "rev-head", headRevisionId: nil), as: UTF8.self)
}

private func fileObject(
    id: String = "file-1",
    name: String = "Notes",
    size: JSONSize = .text("12"),
    headRevision: String? = "rev-head",
    headRevisionId: String? = "rev-id",
    version: String? = nil,
    numericVersion: Int? = nil
) -> [String: Any] {
    var object: [String: Any] = [
        "id": id,
        "name": name,
        "mimeType": "text/plain",
        "parents": ["root"],
        "md5Checksum": "md5",
        "sha1Checksum": "sha1",
        "sha256Checksum": "sha256",
        "owners": [["emailAddress": "a@example.com"], ["emailAddress": "b@example.com"]],
        "webViewLink": "https://example.com/file-1",
        "trashed": false,
        "createdTime": "2020-01-02T03:04:05.000Z",
        "modifiedTime": "2020-01-02T03:05:06Z",
    ]
    switch size {
    case .text(let text):
        object["size"] = text
    case .number(let number):
        object["size"] = number
    }
    if let headRevision {
        object["headRevision"] = headRevision
    }
    if let headRevisionId {
        object["headRevisionId"] = headRevisionId
    }
    if let version {
        object["version"] = version
    }
    if let numericVersion {
        object["version"] = numericVersion
    }
    return object
}

private func sampleFile(headRevision: String) -> DriveFile {
    DriveFile(
        id: DriveID(rawValue: "file-1"),
        name: "Notes",
        mimeType: "text/plain",
        parents: [DriveID(rawValue: "root")],
        size: 12,
        headRevision: headRevision,
        md5: "md5",
        sha1: "sha1",
        sha256: "sha256",
        owner: "a@example.com,b@example.com",
        webViewLink: "https://example.com/file-1",
        trashed: false,
        created: driveDate("2020-01-02T03:04:05.000Z"),
        modified: driveDate("2020-01-02T03:05:06Z")
    )
}

private func driveDate(_ value: String) -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return basic.date(from: value)!
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [FixtureRequest] = []

    func add(_ request: FixtureRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func all() -> [FixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class Marks: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [ContinuousClock.Instant] = []

    func add(_ mark: ContinuousClock.Instant) {
        lock.lock()
        marks.append(mark)
        lock.unlock()
    }

    func all() -> [ContinuousClock.Instant] {
        lock.lock()
        defer { lock.unlock() }
        return marks
    }
}

private struct FixtureRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var port: UInt16
}

private struct FixtureResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

private final class FixtureServer: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var listenFD: Int32
    private var respond: @Sendable (FixtureRequest) -> FixtureResponse
    private let queue = DispatchQueue(label: "gcsf.fixture.http")

    init(respond: @escaping @Sendable (FixtureRequest) -> FixtureResponse) throws {
        self.respond = respond
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureServerError() }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw FixtureServerError()
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw FixtureServerError()
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(fd, raw, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw FixtureServerError()
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddress.sin_port)
        let captured = fd
        queue.async { [weak self] in
            self?.acceptLoop(fd: captured)
        }
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

    private func acceptLoop(fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
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
        guard let request = try? readRequest(fd) else { return }
        lock.lock()
        let handler = respond
        lock.unlock()
        let response = handler(request)
        writeResponse(fd, response)
    }

    private func readRequest(_ fd: Int32) throws -> FixtureRequest {
        let (header, prefetched) = try readHeaders(fd)
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let start = lines.first else { throw FixtureServerError() }
        let parts = start.split(separator: " ")
        guard parts.count >= 2 else { throw FixtureServerError() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(name)] = String(value)
        }
        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") where !pair.isEmpty {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = percentDecode(String(keyValue[0]))
                let value = keyValue.count > 1 ? percentDecode(String(keyValue[1])) : ""
                query[key] = value
            }
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        var body = Data()
        if length > 0 {
            if prefetched.count >= length {
                body = prefetched.prefix(length)
            } else {
                body = prefetched
                body.append(try readCount(fd, length - prefetched.count))
            }
        }
        return FixtureRequest(
            method: String(parts[0]),
            path: String(pieces[0]),
            query: query,
            headers: headers,
            body: body,
            port: port
        )
    }

    private func readHeaders(_ fd: Int32) throws -> (String, Data) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            if data.count > 65_536 { throw FixtureServerError() }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count == 0 { throw FixtureServerError() }
            if count < 0 {
                if errno == EINTR { continue }
                throw FixtureServerError()
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { throw FixtureServerError() }
        let header = String(decoding: data.subdata(in: 0..<marker.lowerBound), as: UTF8.self)
        let rest = data.subdata(in: marker.upperBound..<data.count)
        return (header, rest)
    }

    private func readCount(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 8192))
        while data.count < count {
            let want = min(buffer.count, count - data.count)
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, want)
            }
            if got == 0 { break }
            if got < 0 {
                if errno == EINTR { continue }
                throw FixtureServerError()
            }
            data.append(contentsOf: buffer.prefix(got))
        }
        return data
    }

    private func writeResponse(_ fd: Int32, _ response: FixtureResponse) {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if wrote == 0 { return }
                sent += wrote
            }
        }
    }

    private func percentDecode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 206: "Partial Content"
        case 302: "Found"
        case 308: "Resume Incomplete"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

private struct FixtureServerError: Error {}
