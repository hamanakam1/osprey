import Foundation
import Testing
@testable import OspreyCore

@Suite("Redaction")
struct RedactionTests {
    @Test("secrets are replaced, never echoed")
    func secretsAreReplacedNotEchoed() {
        var redactor = Redactor()
        let input = "export OPENAI_KEY=sk-abcdefghijklmnopqrstuvwxyz123456 and GITHUB=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
        let output = redactor.redact(input)
        #expect(!output.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect(!output.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"))
        #expect(output.contains("[openai-key REDACTED]"))
        #expect(output.contains("[github-token REDACTED]"))
        #expect(redactor.replacements == 2)
    }

    @Test("the marker never reveals the length of a secret")
    func markerNeverRevealsLength() {
        var redactor = Redactor()
        let secret = "sk-" + String(repeating: "a", count: 40)
        let output = redactor.redact("key=\(secret)")
        #expect(!output.contains("aaaa"))
        #expect(output.contains("[openai-key REDACTED]"))
    }

    @Test("ordinary output is left alone")
    func ordinaryOutputIsUntouched() {
        var redactor = Redactor()
        let input = "make: nothing to be done for 'all'\nswift build completed in 12s"
        #expect(redactor.redact(input) == input)
        #expect(redactor.replacements == 0)
    }

    @Test("ANSI sequences are stripped")
    func ansiSequencesAreStripped() {
        let input = "\u{001B}[32mgreen\u{001B}[0m and \u{001B}[1;31mred\u{001B}[0m"
        #expect(Redactor.stripANSI(input) == "green and red")
    }

    @Test("a password in a URL does not survive")
    func basicAuthUrlLosesItsPassword() {
        var redactor = Redactor()
        let output = redactor.redact("git clone https://user:hunter2@example.invalid/repo.git")
        #expect(!output.contains("hunter2"))
        #expect(output.contains("[basic-auth-url REDACTED]"))
    }

    @Test("an assigned secret does not survive")
    func assignedSecretsAreCaught() {
        var redactor = Redactor()
        let output = redactor.redact("password = correct-horse-battery")
        #expect(!output.contains("correct-horse-battery"))
    }

    @Test("command candidates are a bounded heuristic")
    func commandCandidatesAreHeuristicAndBounded() {
        let text = """
        $ git status
        $ make build
        this line is prose and not a command
        ERROR: something failed
        """
        let commands = Redactor.commandCandidates(in: text)
        #expect(commands.contains("git status"))
        #expect(commands.contains("make build"))
        #expect(!commands.contains { $0.hasPrefix("$ ") })
    }

    @Test("failure candidates are found")
    func failureCandidatesAreDetected() {
        let text = """
        build ok
        error: no such module 'Foo'
        Traceback (most recent call last):
        """
        let failures = Redactor.failureCandidates(in: text)
        #expect(!failures.isEmpty)
        #expect(failures.contains { $0.contains("no such module") })
    }
}
