import Foundation

/// Tests run `git config` against throwaway repositories, and git answers from the user's
/// global and system files for any key the repository does not set itself. `arena.baseImage`
/// set globally is what made "git config arena.baseImage overrides the default base" fail:
/// the test asserted on a default the machine had already overridden, and the suite passed
/// or failed depending on whose machine ran it.
///
/// Pointing both outer scopes at /dev/null makes a test see only what it wrote. Set through
/// the process environment rather than per call, because `Repository.config` builds its own
/// `git` invocation and `Shell.run` copies the environment at call time.
enum GitIsolation {
    static let enabled: Void = {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
    }()
}
