import Foundation
import FSKit

@MainActor
@main
struct Doctor {
    static func main() async {
        if ProcessInfo.processInfo.environment["OPEN_SETTINGS"] == "1" {
            _ = FSClient.shared.openFileSystemExtensionsSettings()
        }
        do {
            let installed = try await FSClient.shared.installedExtensions
            print("installedExtensions: \(installed.count)")
            for module in installed {
                print("extension: \(String(describing: module))")
            }
        } catch {
            print("installedExtensions error: \(error)")
        }
    }
}
