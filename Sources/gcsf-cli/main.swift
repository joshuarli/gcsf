import Foundation

@main
struct GCSFCLI {
    static func main() {
        exit(GCSFCommand.run(Array(CommandLine.arguments.dropFirst())))
    }
}

enum GCSFCommand {
    static let help = """
    usage: gcsf <command>

    commands:
      login
      logout
      list
      verify
      mount -s <session>
      umount -s <session>
    """

    static func run(_ args: [String]) -> Int32 {
        if args.contains("--help") || args.contains("-h") || args == ["help"] {
            print(help)
            return 0
        }
        guard let command = args.first else {
            FileHandle.standardError.write(Data((help + "\n").utf8))
            return 2
        }
        let rest = Array(args.dropFirst())
        switch command {
        case "login", "logout", "list", "verify":
            guard rest.isEmpty else {
                FileHandle.standardError.write(Data((help + "\n").utf8))
                return 2
            }
            FileHandle.standardError.write(Data("\(command): not implemented\n".utf8))
            return 1
        case "mount":
            return sessionCommand(rest, parked: "runtime mount is parked\n", usage: mountUsage)
        case "umount":
            return sessionCommand(rest, parked: "runtime umount is parked\n", usage: umountUsage)
        default:
            FileHandle.standardError.write(Data((help + "\n").utf8))
            return 2
        }
    }

    private static let mountUsage = """
    usage: gcsf mount -s <session>
    the OS returns the mount URL

    """

    private static let umountUsage = """
    usage: gcsf umount -s <session>

    """

    private static func sessionCommand(_ args: [String], parked: String, usage: String) -> Int32 {
        var session: String?
        var positionals: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-s" {
                guard index + 1 < args.count, session == nil else {
                    FileHandle.standardError.write(Data(usage.utf8))
                    return 2
                }
                index += 1
                session = args[index]
            } else if arg.hasPrefix("-") {
                FileHandle.standardError.write(Data(usage.utf8))
                return 2
            } else {
                positionals.append(arg)
            }
            index += 1
        }
        if session == nil || !positionals.isEmpty {
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        print(parked, terminator: "")
        return 1
    }
}
