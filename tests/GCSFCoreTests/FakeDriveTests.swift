import Foundation
import Testing
import GCSFCore
import GCSFTestSupport

@Suite struct FakeDriveTests {
    @Test func roundTrip() async throws {
        let drive = FakeDrive()
        let about = try await drive.about()
        #expect(about.rootFolderID == DriveID(rawValue: "root"))
        #expect(about.userEmail == "owner@example.com")
        try await drive.refreshCredential()
        let token = try await drive.startPageToken()
        #expect(token == "0")

        let root = about.rootFolderID
        let notes = try await drive.createFile(metadata: meta("notes", parents: [root]))
        let folder = try await drive.createFile(metadata: meta("folder", "application/vnd.google-apps.folder", parents: [root]))
        let child = try await drive.createFile(metadata: meta("child", parents: [folder.id]))
        let doomed = try await drive.createFile(metadata: meta("doomed", parents: [root]))
        let trashed = try await drive.updateFile(id: doomed.id, metadata: DriveFileUpdate(name: nil, mimeType: nil, parents: nil, trashed: true))
        #expect(trashed.trashed == true)
        let renamed = try await drive.updateFile(id: notes.id, metadata: DriveFileUpdate(name: "renamed", mimeType: nil, parents: nil, trashed: nil))
        #expect(try await drive.getFile(id: notes.id) == renamed)
        let blob = try await drive.multipartUpload(upload("blob", Data("hello".utf8), [root]))
        let doc = try await drive.createFile(metadata: meta("doc", "application/vnd.google-apps.document", parents: [root]))

        let everything = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(everything.files.map(\.name) == ["renamed", "folder", "child", "doomed", "blob", "doc"])
        let alive = try await drive.listFiles(query: "trashed = false and '\(root.rawValue)' in parents", pageToken: nil, pageSize: nil)
        #expect(alive.files.map(\.name) == ["renamed", "folder", "blob", "doc"])
        let trash = try await drive.listFiles(query: "trashed = true", pageToken: nil, pageSize: nil)
        #expect(trash.files.map(\.id) == [doomed.id])
        let children = try await drive.listFiles(query: "'\(folder.id.rawValue)' in parents", pageToken: nil, pageSize: nil)
        #expect(children.files.map(\.id) == [child.id])
        let first = try await drive.listFiles(query: "trashed = false and '\(root.rawValue)' in parents", pageToken: nil, pageSize: 1)
        #expect(first.files.map(\.name) == ["renamed"])
        #expect(first.nextPageToken == "1")
        let replay = try await drive.listFiles(query: "trashed = false and '\(root.rawValue)' in parents", pageToken: nil, pageSize: 1)
        #expect(replay == first)
        let second = try await drive.listFiles(query: "trashed = false and '\(root.rawValue)' in parents", pageToken: first.nextPageToken, pageSize: 1)
        #expect(second.files.map(\.name) == ["folder"])
        await #expect(throws: FakeDriveError.unknownQuery("name = 'x'")) {
            _ = try await drive.listFiles(query: "name = 'x'", pageToken: nil, pageSize: nil)
        }
        await #expect(throws: FakeDriveError.unknownQuery("'root' in parents or trashed = false")) {
            _ = try await drive.listFiles(query: "'root' in parents or trashed = false", pageToken: nil, pageSize: nil)
        }

        let whole = try await drive.downloadContent(id: blob.id, range: nil)
        #expect(whole.bytes == Data("hello".utf8))
        #expect(whole.offset == 0)
        #expect(whole.totalSize == 5)
        let window = try await drive.downloadContent(id: blob.id, range: ByteRange(offset: 1, length: 2))
        #expect(window.bytes == Data("el".utf8))
        #expect(window.offset == 1)
        #expect(window.totalSize == 5)
        let tail = try await drive.downloadContent(id: blob.id, range: ByteRange(offset: 1, length: nil))
        #expect(tail.bytes == Data("ello".utf8))
        #expect(try await drive.exportFile(id: blob.id, mimeType: "text/plain") == Data("hello".utf8))
        let native = Data("Google-native document".utf8)
        #expect(try await drive.exportFile(id: doc.id, mimeType: "text/plain") == native)
        #expect(try await drive.exportFile(id: folder.id, mimeType: "text/plain") == native)
        #expect(try await drive.exportFile(id: renamed.id, mimeType: "text/plain") == Data())
        let replaced = try await drive.multipartUpload(upload("blob", Data("yo".utf8), [root], existing: blob.id))
        #expect(replaced.id == blob.id)
        #expect(try await drive.downloadContent(id: blob.id, range: nil).bytes == Data("yo".utf8))

        let partial = try await drive.startResumableUpload(resumable("part", 4, [root]))
        let held = try await drive.resumeUpload(session: partial, chunk: DriveUploadChunk(offset: 0, bytes: Data("ab".utf8), isLast: false))
        #expect(held.completedFile == nil)
        #expect(held.indeterminate == false)
        #expect(held.committedOffset == 2)
        let finished = try await drive.resumeUpload(session: partial, chunk: DriveUploadChunk(offset: 2, bytes: Data("cd".utf8), isLast: true))
        let finishedFile = try #require(finished.completedFile)
        #expect(finished.indeterminate == false)
        #expect(finished.committedOffset == 4)
        #expect(try await drive.downloadContent(id: finishedFile.id, range: nil).bytes == Data("abcd".utf8))

        let short = try await drive.startResumableUpload(resumable("short", 4, [root]))
        let earlyEnd = try await drive.resumeUpload(session: short, chunk: DriveUploadChunk(offset: 0, bytes: Data("ab".utf8), isLast: true))
        #expect(earlyEnd.completedFile == nil)
        #expect(earlyEnd.committedOffset == 2)
        let open = try await drive.startResumableUpload(resumable("open", 2, [root]))
        let unmarked = try await drive.resumeUpload(session: open, chunk: DriveUploadChunk(offset: 0, bytes: Data("xy".utf8), isLast: false))
        #expect(unmarked.completedFile == nil)
        #expect(unmarked.committedOffset == 2)
        let marked = try await drive.resumeUpload(session: open, chunk: DriveUploadChunk(offset: 2, bytes: Data(), isLast: true))
        #expect(marked.completedFile?.name == "open")
        let names = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(names.files.contains { $0.name == "short" } == false)
        #expect(names.files.contains { $0.name == "part" })
        #expect(names.files.contains { $0.name == "open" })

        try await drive.deleteFile(id: doomed.id)
        await #expect(throws: FakeDriveError.notFound(doomed.id)) {
            _ = try await drive.getFile(id: doomed.id)
        }
        let page = try await drive.listChanges(pageToken: token, pageSize: 1)
        #expect(page.changes.map(\.fileID) == [notes.id])
        #expect(page.changes.first?.file?.name == "notes")
        #expect(page.changes.first?.removed == false)
        #expect(page.nextPageToken == "1")
        #expect(page.newStartPageToken == nil)
        let repeated = try await drive.listChanges(pageToken: token, pageSize: 1)
        #expect(repeated == page)
        let next = try await drive.listChanges(pageToken: try #require(page.nextPageToken), pageSize: 1)
        #expect(next.changes.first?.fileID != notes.id)
        let settled = try await drive.listChanges(pageToken: token, pageSize: nil)
        #expect(settled.nextPageToken == nil)
        let cursor = try #require(settled.newStartPageToken)
        #expect(try await drive.startPageToken() == cursor)
        #expect(settled.changes.contains { $0.fileID == notes.id && $0.file?.name == "renamed" })
        #expect(settled.changes.contains { $0.fileID == doomed.id && $0.removed && $0.file == nil })
        let quiet = try await drive.listChanges(pageToken: cursor, pageSize: nil)
        #expect(quiet.changes.isEmpty)
        #expect(quiet.newStartPageToken == cursor)
        let extra = try await drive.createFile(metadata: meta("extra", parents: [root]))
        let delta = try await drive.listChanges(pageToken: cursor, pageSize: nil)
        #expect(delta.changes.map(\.fileID) == [extra.id])
        #expect(try await drive.listChanges(pageToken: token, pageSize: 1) == page)
    }

    @Test func unauthorizedIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.unauthorized)
        await #expect(throws: FakeDriveError.unauthorized) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func refreshFailureIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.refreshFailure)
        await #expect(throws: FakeDriveError.refreshFailure) {
            try await drive.refreshCredential()
        }
        try await drive.refreshCredential()
        #expect(try await drive.about().userEmail == "owner@example.com")
    }

    @Test func forbiddenIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.forbidden)
        await #expect(throws: FakeDriveError.forbidden) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func rateLimitedIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.rateLimited)
        await #expect(throws: FakeDriveError.rateLimited) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func serverErrorIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.serverError)
        await #expect(throws: FakeDriveError.server) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func malformedMetadataIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.malformedMetadata)
        await #expect(throws: FakeDriveError.malformedMetadata) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func timeoutIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.timeout)
        await #expect(throws: FakeDriveError.timeout) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func cancellationIsOneShot() async throws {
        let drive = FakeDrive()
        await drive.arm(.cancellation)
        await #expect(throws: CancellationError.self) {
            _ = try await drive.about()
        }
        #expect(try await drive.about().rootFolderID == DriveID(rawValue: "root"))
    }

    @Test func partialDownloadIsShortAndOneShot() async throws {
        let drive = FakeDrive()
        let file = try await drive.multipartUpload(upload("a", Data("hello".utf8), []))
        await drive.arm(.partialDownload)
        let short = try await drive.downloadContent(id: file.id, range: nil)
        #expect(short.bytes == Data("hell".utf8))
        #expect(short.offset == 0)
        #expect(short.totalSize == 5)
        let full = try await drive.downloadContent(id: file.id, range: nil)
        #expect(full.bytes == Data("hello".utf8))
        #expect(full.totalSize == 5)
    }

    @Test func resume308IsProgressWithoutAFile() async throws {
        let drive = FakeDrive()
        let intent = resumable("up", 4, [])
        let session = try await drive.startResumableUpload(intent)
        await drive.arm(.resumeIncomplete)
        let held = try await drive.resumeUpload(session: session, chunk: DriveUploadChunk(offset: 0, bytes: Data("abcd".utf8), isLast: true))
        #expect(held.completedFile == nil)
        #expect(held.indeterminate == false)
        #expect(held.committedOffset == 4)
        let hidden = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(hidden.files.contains { $0.name == "up" } == false)
        let again = try await drive.startResumableUpload(intent)
        let done = try await drive.resumeUpload(session: again, chunk: DriveUploadChunk(offset: 0, bytes: Data("abcd".utf8), isLast: true))
        #expect(done.indeterminate == false)
        #expect(done.completedFile?.name == "up")
        #expect(done.committedOffset == 4)
        let visible = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(visible.files.map(\.name) == ["up"])
    }

    @Test func redirectIsRecordedWithoutHTTP() async throws {
        let drive = FakeDrive()
        await drive.arm(.redirect)
        await #expect(throws: FakeDriveError.redirect(FakeDriveError.redirectLocation)) {
            _ = try await drive.createFile(metadata: meta("x", parents: []))
        }
        #expect(await drive.redirects == [FakeDriveError.redirectLocation])
        let hidden = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(hidden.files.isEmpty)
        let created = try await drive.createFile(metadata: meta("x", parents: []))
        #expect(created.name == "x")
    }

    @Test func indeterminateUploadDoesNotPublish() async throws {
        let drive = FakeDrive()
        let session = try await drive.startResumableUpload(resumable("up", 4, []))
        await drive.arm(.indeterminate)
        let held = try await drive.resumeUpload(session: session, chunk: DriveUploadChunk(offset: 0, bytes: Data("abcd".utf8), isLast: true))
        #expect(held.indeterminate == true)
        #expect(held.completedFile == nil)
        #expect(held.committedOffset == 0)
        let hidden = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(hidden.files.isEmpty)
        let done = try await drive.resumeUpload(session: session, chunk: DriveUploadChunk(offset: 0, bytes: Data("abcd".utf8), isLast: true))
        #expect(done.indeterminate == false)
        #expect(done.completedFile?.name == "up")
        #expect(done.committedOffset == 4)
        let visible = try await drive.listFiles(query: nil, pageToken: nil, pageSize: nil)
        #expect(visible.files.map(\.name) == ["up"])
    }
}

private func meta(_ name: String, _ mime: String = "text/plain", parents: [DriveID]) -> DriveFileCreate {
    DriveFileCreate(name: name, mimeType: mime, parents: parents)
}

private func upload(_ name: String, _ body: Data, _ parents: [DriveID], existing: DriveID? = nil) -> MultipartUploadIntent {
    MultipartUploadIntent(existingFileID: existing, metadata: meta(name, parents: parents), mimeType: "text/plain", body: body)
}

private func resumable(_ name: String, _ total: Int64, _ parents: [DriveID]) -> ResumableUploadIntent {
    ResumableUploadIntent(existingFileID: nil, metadata: meta(name, parents: parents), mimeType: "text/plain", totalSize: total)
}
