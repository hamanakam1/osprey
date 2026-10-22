import Foundation

/// Where Osprey keeps its own files, and where Taskrivet keeps its files.
///
/// Everything is resolved from explicit inputs with a documented fallback.
/// Nothing is guessed silently: a missing path is reported, not invented.
public enum OspreyPaths {
    public static func home(_ fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    /// The Osprey state directory. `OSPREY_HOME` overrides it for tests.
    public static func stateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["OSPREY_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return home(fileManager).appendingPathComponent(".osprey", isDirectory: true)
    }

    public static func evidenceDatabase(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        stateDirectory(environment: environment, fileManager: fileManager).appendingPathComponent("evidence.sqlite")
    }

    public static func proposalsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        stateDirectory(environment: environment, fileManager: fileManager).appendingPathComponent("proposals", isDirectory: true)
    }

    public static func receiptsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        stateDirectory(environment: environment, fileManager: fileManager).appendingPathComponent("receipts", isDirectory: true)
    }

    public static func ensureStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: stateDirectory(environment: environment, fileManager: fileManager),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

/// Locates the Taskrivet installation Osprey works with.
public enum TaskrivetLocator {
    /// The ledger database Taskrivet uses. `TASKRIVET_DB` wins.
    public static func ledgerDatabase(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["TASKRIVET_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".taskrivet", isDirectory: true)
            .appendingPathComponent("ledger.sqlite")
    }

    /// The private session-service directory Taskrivet derives from the database path.
    ///
    /// Taskrivet hashes the resolved database path; Osprey reproduces the same
    /// derivation so it can find the live socket without being told twice.
    public static func sessionRuntimeDirectory(
        database: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let resolved = database.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256Lite.hexDigest(of: resolved)
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".taskrivet", isDirectory: true)
            .appendingPathComponent("sessions-" + String(digest.prefix(12)), isDirectory: true)
    }

    public static func sessionSocket(runtimeDirectory: URL) -> URL {
        runtimeDirectory.appendingPathComponent("sessions.sock")
    }

    public static func sessionToken(runtimeDirectory: URL) -> URL {
        runtimeDirectory.appendingPathComponent("token")
    }

    /// The Python package root that contains the `taskrivet` module.
    ///
    /// `TASKRIVET_CORE` wins. Otherwise Osprey looks in the usual local places,
    /// including the packaged desktop app, and reports what it tried.
    public static func coreRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["TASKRIVET_CORE"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return fileManager.fileExists(atPath: url.appendingPathComponent("taskrivet").path) ? url : nil
        }
        var candidates: [URL] = []
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Projects/taskrivet"))
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Projects/Taskrivet"))
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".taskrivet/core"))
        candidates.append(URL(fileURLWithPath: "/Applications/Taskrivet.app/Contents/Resources/core"))
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Taskrivet.app/Contents/Resources/core")
        )
        return candidates.first { candidate in
            fileManager.fileExists(atPath: candidate.appendingPathComponent("taskrivet").path)
        }
    }

    /// Every place Osprey looked, for a clear failure message.
    public static func coreRootSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates: [URL] = []
        if let override = environment["TASKRIVET_CORE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Projects/taskrivet"))
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Projects/Taskrivet"))
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".taskrivet/core"))
        candidates.append(URL(fileURLWithPath: "/Applications/Taskrivet.app/Contents/Resources/core"))
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Taskrivet.app/Contents/Resources/core")
        )
        return candidates
    }
}

/// A small SHA-256 so the runtime-directory derivation matches Taskrivet's.
enum SHA256Lite {
    static func hexDigest(of string: String) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        let message = Array(string.utf8)
        let bitLength = UInt64(message.count) * 8
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8truncating(bitLength >> UInt64(shift)))
        }

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(padded[base]) << 24) | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8) | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        for (index, value) in h.enumerated() {
            digest[index * 4] = UInt8((value >> 24) & 0xff)
            digest[index * 4 + 1] = UInt8((value >> 16) & 0xff)
            digest[index * 4 + 2] = UInt8((value >> 8) & 0xff)
            digest[index * 4 + 3] = UInt8(value & 0xff)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static func UInt8truncating(_ value: UInt64) -> UInt8 {
        UInt8(value & 0xff)
    }
}
