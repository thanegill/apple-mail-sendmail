import Foundation

public final class TempDir {
    public let url: URL

    public init() throws {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("sendmail-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.url = dir
    }

    @discardableResult
    public func write(_ data: Data, name: String) throws -> URL {
        let dest = url.appendingPathComponent(name)
        try data.write(to: dest)
        return dest
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

public func sanitizeFilename(_ raw: String, fallback: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let s = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    if s.isEmpty { return fallback }
    return String(s.prefix(120))
}
