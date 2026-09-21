import Foundation

/// A failed subprocess, carrying enough to say which one and why.
struct CommandFailure: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let stderr: String

    var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "\(command) exited \(status)"
            : "\(command) exited \(status): \(detail)"
    }
}

/// Every external tool arena drives goes through here.
///
/// arena is an orchestrator: it spends its time in `container`, `git`, `gh` and `herdr`
/// rather than in its own code, so the subprocess call is the primitive worth getting
/// right. Arguments are passed as an array and never as a shell string, which is what
/// keeps a repository path containing a space from becoming a quoting bug.
enum Shell {
    /// Homebrew is not on the PATH of a process launched outside a login shell, and
    /// `container` lives there.
    static let searchPath = ["/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = workingDirectory

        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? ""
        env["PATH"] = (searchPath + [existing]).joined(separator: ":")
        env.merge(environment) { _, new in new }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        // Read before waiting. A pipe buffer that fills while the child is still writing
        // deadlocks both processes, and `container build` produces more than enough output
        // to reach that.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CommandFailure(
                command: ([executable] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run and hand the terminal over, for the agent process itself.
    @discardableResult
    static func exec(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = workingDirectory

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Hand the terminal over for good, by replacing arena's own process.
    ///
    /// `Process` puts its child in a new process group, which is a background group for the
    /// controlling terminal. `container run -t` then takes SIGTTOU setting the pty to raw mode
    /// and SIGTTIN reading stdin, so the agent draws its interface and accepts no keystroke.
    /// `execvp` keeps the pid, the process group and the terminal the shell gave arena, so the
    /// agent is the foreground job exactly as it is when `container run` is typed by hand.
    static func replace(_ executable: String, _ arguments: [String]) throws -> Never {
        let path = (searchPath + [ProcessInfo.processInfo.environment["PATH"] ?? ""])
            .joined(separator: ":")
        setenv("PATH", path, 1)

        // Anything arena has printed is still in its own stdio buffers when stdout is not a
        // tty, and exec discards them.
        fflush(nil)

        let argv = [executable] + arguments
        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        pointers.append(nil)
        execvp(executable, &pointers)

        // Only reached when the exec itself failed; the image is otherwise already gone.
        throw CommandFailure(
            command: argv.joined(separator: " "),
            status: errno,
            stderr: String(cString: strerror(errno))
        )
    }

    /// Exit status only, for the checks where a non-zero is an answer rather than a fault.
    static func succeeds(_ executable: String, _ arguments: [String]) -> Bool {
        (try? run(executable, arguments)) != nil
    }
}
