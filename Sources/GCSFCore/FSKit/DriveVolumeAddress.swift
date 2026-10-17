import Foundation

public enum DriveVolumeAddress: Sendable {
    public static func session(from url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare("gdrive") == .orderedSame else { return nil }
        guard url.user == nil, url.password == nil, url.port == nil else { return nil }
        guard url.query == nil, url.fragment == nil else { return nil }
        guard url.path.isEmpty || url.path == "/" else { return nil }
        guard let host = url.host, host.isEmpty == false else { return nil }
        return host
    }

    public static func url(session: String) -> URL? {
        guard session.isEmpty == false else { return nil }
        var components = URLComponents()
        components.scheme = "gdrive"
        components.host = session
        guard let url = components.url, Self.session(from: url) == session else { return nil }
        return url
    }
}
