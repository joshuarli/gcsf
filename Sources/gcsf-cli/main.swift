import Foundation
import GCSFCore

@main
struct GCSFCLI {
    static func main() {
        let result = GCSFCommandLine.execute(
            Array(CommandLine.arguments.dropFirst()),
            environment: .live(unmount: CLIUnmount.run)
        )
        if result.out.isEmpty == false {
            FileHandle.standardOutput.write(Data(result.out.utf8))
        }
        if result.err.isEmpty == false {
            FileHandle.standardError.write(Data(result.err.utf8))
        }
        exit(result.code)
    }
}

enum CLIUnmount {
    static func run(_ url: URL) throws {
        guard url.isFileURL else { throw POSIXError(.EINVAL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = ["--", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "umount failed" : message]
            )
        }
    }
}
