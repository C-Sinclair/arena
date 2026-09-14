import Foundation
import Testing

@testable import arena

@Suite("Shell")
struct ShellTests {
    @Test("stdout comes back trimmed")
    func capturesOutput() throws {
        #expect(try Shell.run("echo", ["hello"]) == "hello")
    }

    @Test("arguments are passed as a vector, so a space is not a word boundary")
    func argumentsAreNotReparsed() throws {
        // The bug this rewrite exists to prevent: a path with a space in it must survive.
        #expect(try Shell.run("echo", ["-n", "two words"]) == "two words")
    }

    @Test("a non-zero exit throws, carrying the command, the status and stderr")
    func failureCarriesContext() {
        #expect(throws: CommandFailure.self) {
            try Shell.run("sh", ["-c", "echo boom >&2; exit 3"])
        }
        do {
            _ = try Shell.run("sh", ["-c", "echo boom >&2; exit 3"])
        } catch let failure as CommandFailure {
            #expect(failure.status == 3)
            #expect(failure.stderr.contains("boom"))
            #expect(failure.description.contains("boom"))
        } catch {
            Issue.record("expected a CommandFailure, got \(error)")
        }
    }

    @Test("output larger than a pipe buffer does not deadlock")
    func largeOutput() throws {
        // stdout and stderr are read before waitUntilExit for this reason. A container build
        // produces far more than a 64 KB pipe buffer.
        let output = try Shell.run("sh", ["-c", "yes abcdefgh | head -n 40000"])
        #expect(output.count > 300_000)
    }

    @Test("succeeds reports an exit status without throwing")
    func succeedsIsAQuestion() {
        #expect(Shell.succeeds("true", []))
        #expect(!Shell.succeeds("false", []))
    }

    @Test("Homebrew is on the search path, because container lives there")
    func searchPathIncludesHomebrew() {
        #expect(Shell.searchPath.contains("/opt/homebrew/bin"))
    }
}
