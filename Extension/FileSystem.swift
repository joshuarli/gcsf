import ExtensionFoundation
import Foundation
import FSKit
import GCSFCore

@main
struct GCSFExtensionMain: UnaryFileSystemExtension {
    let fileSystem = GCSFFileSystem(makeEngine: { session in
        LiveSession.production(session: session, tokens: KeychainRefreshTokenStore())
    })
}
