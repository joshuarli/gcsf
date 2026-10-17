# Parity

Level 1 is FakeDrive, the index, the engine, the cache, the journal, or the change feed. Level 2 is DriveClientTests and AuthTests. Level 3 is the signed mount and is unverified. A level 3 row names a category in `tests/integration/test_filesystem_operations.sh`. It is not a result.

Later suites are level 1 unless named here: EngineTests, CacheTests, WritebackTests, SyncTests, AdversarialTests, and the session commands in FSKitAdapterTests. AuthTests and ConfigTests are level 2. They are not a kernel mount.

| behavior | test | level |
| --- | --- | --- |
| restart keeps inodes, names, suffixes, and Drive ids | restartKeepsInodesNamesSuffixesAndDriveIDs | 1 |
| reserved directories keep inodes across restart | reservedDirectoriesKeepInodesAcrossRestart | 1 |
| a second insert does not change an existing suffix | secondInsertDoesNotChangeExistingSuffix | 1 |
| a duplicate Drive id on insert throws | duplicateDriveIDOnInsertThrows | 1 |
| delete removes lookup by inode and Drive id | deleteRemovesLookupByInodeAndDriveID | 1 |
| child lookup uses the parent and base name | childLookupUsesParentAndBaseName | 1 |
| attributes round-trip | attributesRoundTrip | 1 |
| a failed update leaves the row in place | failedUpdateLeavesTheRowInPlace | 1 |
| a deleted inode is not reused until restart | deletedInodeIsNotReusedUntilRestart | 1 |
| a missing column fails open | missingColumnFailsOpen | 1 |
| list, get, create, update, delete, export, ranged download, multipart upload, resumable upload, page token, changes, about, and refresh | roundTrip | 1 |
| unauthorized is one shot | unauthorizedIsOneShot | 1 |
| refresh failure is one shot | refreshFailureIsOneShot | 1 |
| forbidden is one shot | forbiddenIsOneShot | 1 |
| rate limited is one shot | rateLimitedIsOneShot | 1 |
| server error is one shot | serverErrorIsOneShot | 1 |
| malformed metadata is one shot | malformedMetadataIsOneShot | 1 |
| timeout is one shot | timeoutIsOneShot | 1 |
| cancellation throws CancellationError once | cancellationIsOneShot | 1 |
| partial download returns a short body once | partialDownloadIsShortAndOneShot | 1 |
| a 308 resume reports progress and does not publish | resume308IsProgressWithoutAFile | 1 |
| a redirect is recorded and is not an HTTP fetch | redirectIsRecordedWithoutHTTP | 1 |
| an indeterminate resume does not publish | indeterminateUploadDoesNotPublish | 1 |
| files.list returns one page until the caller passes the token | paginationReturnsOnePageUntilTheCallerPassesTheToken | 2 |
| one 401 refreshes once and then succeeds | unauthorizedRefreshesOnceThenSucceeds | 2 |
| a second 401 does not refresh again | secondUnauthorizedDoesNotRefreshAgain | 2 |
| a 308 response recovers the committed offset | resumable308RecoversCommittedOffset | 2 |
| an empty or truncated resumable body stays indeterminate | resumableEmptyOrTruncatedBodyIsIndeterminate | 2 |
| a cross-origin redirect drops the bearer and a same-origin redirect keeps it | crossOriginRedirectDropsTheBearerAndSameOriginKeepsIt | 2 |
| retry honors Retry-After inside the test bound | retryHonorsRetryAfterWithTheTestRetryBound | 2 |
| forbidden, not found, conflict, and server errors stay distinct | forbiddenNotFoundConflictAndServerAreDistinct | 2 |
| cancellation during retry throws and does not retry | cancellationDuringRetryThrowsAndDoesNotRetry | 2 |
| download sends the range and does not keep bytes past the requested length | downloadSendsRangeAndDoesNotKeepBytesPastTheRequestedLength | 2 |
| about maps the root id and user email | aboutMapsRootIDAndUserEmail | 2 |
| a missing about root uses a dedicated root request | aboutMissingRootUsesADedicatedRequest | 2 |
| get maps the version fixture alias onto head revision | getFileMapsVersionFixtureAliasOntoHeadRevision | 2 |
| get maps headRevisionId when headRevision is absent | getFileMapsHeadRevisionIdWhenHeadRevisionIsAbsent | 2 |
| create, update, delete, export, and multipart use Drive paths | metadataCreateUpdateDeleteExportAndMultipartUseDrivePaths | 2 |
| resumable upload reads Location and changes.list returns one page | startResumableUploadReadsTheLocationAndChangesListOnePage | 2 |
| refreshCredential uses the same closure as a 401 | refreshCredentialUsesTheSameClosureAsUnauthorized | 2 |
| basic file creation | test_file_creation | 3 unverified |
| writing to files, including overwrite and append | test_file_writing | 3 unverified |
| reading from files | test_file_reading | 3 unverified |
| moving and renaming files | test_file_moving | 3 unverified |
| deleting files | test_file_deletion | 3 unverified |
| directory operations | test_directory_operations | 3 unverified |
| large file handling | test_large_files | 3 unverified |
| special characters in filenames | test_special_characters | 3 unverified |
| file content integrity | test_content_integrity | 3 unverified |
| concurrent file operations | test_concurrent_operations | 3 unverified |
| file copy operations | test_copy_operations | 3 unverified |
| duplicate file handling in the same directory | test_duplicate_same_directory | 3 unverified |
| the same filename in different directories | test_same_name_different_dirs | 3 unverified |
| the same filename in nested directories | test_nested_same_names | 3 unverified |
| sequential reading of a large file | test_large_file_sequential_read | 3 unverified |
| Drive xattrs | test_drive_xattrs | 3 unverified |
