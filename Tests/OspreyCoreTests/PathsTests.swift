import Foundation
import Testing
@testable import OspreyCore

@Suite("Paths")
struct PathsTests {
    @Test("SHA-256 matches the reference digests")
    func sha256MatchesKnownDigests() {
        #expect(
            SHA256Lite.hexDigest(of: "")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            SHA256Lite.hexDigest(of: "abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            SHA256Lite.hexDigest(of: "/tmp/osprey-test/ledger.sqlite")
                == "7fdd8f23fa36c58aa89c4eb2ffc8a673db5d3d7253690f44cd7f4076e54a6a20"
        )
    }

    @Test("the runtime directory matches the Taskrivet derivation")
    func runtimeDirectoryMatchesTaskrivetDerivation() {
        let database = URL(fileURLWithPath: "/tmp/osprey-test/ledger.sqlite")
        let runtime = TaskrivetLocator.sessionRuntimeDirectory(database: database)
        #expect(runtime.lastPathComponent == "sessions-7fdd8f23fa36")
        #expect(runtime.deletingLastPathComponent().lastPathComponent == ".taskrivet")
    }

    @Test("the socket and the token live inside the runtime directory")
    func socketAndTokenLiveInsideTheRuntimeDirectory() {
        let runtime = TaskrivetLocator.sessionRuntimeDirectory(database: URL(fileURLWithPath: "/tmp/osprey-test/ledger.sqlite"))
        #expect(TaskrivetLocator.sessionSocket(runtimeDirectory: runtime).lastPathComponent == "sessions.sock")
        #expect(TaskrivetLocator.sessionToken(runtimeDirectory: runtime).lastPathComponent == "token")
    }

    @Test("the environment overrides the database path")
    func environmentOverrideWinsForTheDatabase() {
        let overridden = TaskrivetLocator.ledgerDatabase(environment: ["TASKRIVET_DB": "/tmp/custom.sqlite"])
        #expect(overridden.path == "/tmp/custom.sqlite")
    }

    @Test("the state directory can be overridden")
    func stateDirectoryCanBeOverridden() {
        let overridden = OspreyPaths.stateDirectory(environment: ["OSPREY_HOME": "/tmp/osprey-home"])
        #expect(overridden.path == "/tmp/osprey-home")
    }

    @Test("the core root search paths are reported")
    func coreRootSearchPathsAreReported() {
        let paths = TaskrivetLocator.coreRootSearchPaths(environment: [:]).map(\.path)
        #expect(!paths.isEmpty)
        #expect(paths.contains { $0.hasSuffix("Projects/taskrivet") })
    }
}
