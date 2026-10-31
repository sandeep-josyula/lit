import Foundation
import CryptoKit

/// Non-destructive edit storage. Edits live in Application Support, keyed by the
/// photo's path, so photo folders stay untouched.
public enum Sidecar {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LIT/Edits", isDirectory: true)
        // Carry over edits made while the app was called AURA or Lumen.
        let fm = FileManager.default
        for name in ["AURA", "Lumen"] where !fm.fileExists(atPath: dir.path) {
            let old = base.appendingPathComponent("\(name)/Edits", isDirectory: true)
            guard fm.fileExists(atPath: old.path) else { continue }
            try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: dir)
        }
        return dir
    }()

    static func file(for photo: URL) -> URL {
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    public static func load(for photo: URL) -> Adjustments? {
        guard let data = try? Data(contentsOf: file(for: photo)) else { return nil }
        return try? JSONDecoder().decode(Adjustments.self, from: data)
    }

    public static func save(_ adj: Adjustments, for photo: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(adj) {
            try? data.write(to: file(for: photo), options: .atomic)
        }
    }
}
