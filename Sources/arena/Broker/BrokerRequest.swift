import Foundation

/// A request a sandbox wrote into `/var/lib/arena/spawn`, which is `<state>/spawn` on the
/// host. See ADR-010 for what each kind may do.
///
/// Decoded narrowly: an unknown field is ignored, so `arena-spawn`'s `base` and
/// `requested_at` are not an error. A missing `kind` is, because the lane requests
/// `arena-spawn` writes have no host-side handler yet.
struct BrokerRequest: Decodable, Equatable {
    let kind: String?
    let name: String?
    let brief: String?
    let model: String?
    let effort: String?
    let path: String?
}

/// What the broker does for a request that passed validation. Nothing reaches a subprocess
/// before it is one of these.
enum BrokerAction: Equatable {
    /// An agent in a Herdr split beside the leader, inside the leader's own container.
    case split(name: String, brief: String, model: String, effort: String)
    /// Tell the leader that `/var/lib/arena/findings/<name>.md` is ready.
    case report(name: String)
    /// Open another repository's sandbox in a new tab, once the user has said yes.
    case hop(repository: URL)
}

struct BrokerRejection: Error, Equatable, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

enum BrokerProtocol {
    /// The same pattern `arena-spawn` holds names to. `lane`, `herdr` and `container` all
    /// accept it, so the name is never escaped for any of them.
    static var namePattern: Regex<Substring> { #/^[a-z0-9][a-z0-9._\/-]{0,62}$/# }

    static let models: Set<String> = ["opus", "sonnet", "haiku", "fable"]
    static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    static let splitModel = "opus"
    static let splitEffort = "xhigh"

    /// A brief over this size is refused rather than written to disk. A request file is
    /// written by an agent that skips permissions, and the host keeps every brief.
    static let maximumBriefBytes = 64 * 1024

    static func validate(_ request: BrokerRequest, home: URL) -> Result<
        BrokerAction, BrokerRejection
    > {
        switch request.kind {
        case "split":
            guard let name = request.name, validName(name) else { return reject("name", request) }
            guard let brief = request.brief, !brief.isEmpty else {
                return .failure(BrokerRejection(reason: "split '\(name)' has an empty brief"))
            }
            guard brief.utf8.count <= maximumBriefBytes else {
                return .failure(BrokerRejection(reason: "split '\(name)' brief is over 64 KiB"))
            }
            let model = request.model ?? splitModel
            guard models.contains(model) else { return reject("model", request) }
            let effort = request.effort ?? splitEffort
            guard efforts.contains(effort) else { return reject("effort", request) }
            return .success(.split(name: name, brief: brief, model: model, effort: effort))

        case "report":
            guard let name = request.name, validName(name) else { return reject("name", request) }
            return .success(.report(name: name))

        case "hop":
            guard let path = request.path, let repository = hopTarget(path, home: home) else {
                return .failure(
                    BrokerRejection(
                        reason: "hop path '\(request.path ?? "")' is not ~/Repos/ORG/REPO"))
            }
            return .success(.hop(repository: repository))

        case nil:
            return .failure(BrokerRejection(reason: "request has no kind"))

        case let other?:
            return .failure(BrokerRejection(reason: "unknown request kind '\(other)'"))
        }
    }

    static func validName(_ name: String) -> Bool {
        name.wholeMatch(of: namePattern) != nil
    }

    /// The name as one path component. The pattern allows `/`, so `a/../../x` would
    /// otherwise climb out of the findings directory; with `/` gone no `..` component is
    /// left, since a name cannot start with `.`.
    static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }

    /// `~/Repos/ORG/REPO`, exactly two levels under `~/Repos`, as either `~/...` or an
    /// absolute host path. Symlinks are not resolved here: the caller checks the directory
    /// exists, and a symlink under `~/Repos` was put there by the user.
    static func hopTarget(_ path: String, home: URL) -> URL? {
        let expanded: String
        if path == "~" || path.hasPrefix("~/") {
            expanded = home.path + path.dropFirst()
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            return nil
        }

        let repos = home.appendingPathComponent("Repos").standardizedFileURL.pathComponents
        let target = URL(fileURLWithPath: expanded).standardizedFileURL
        let components = target.pathComponents
        guard components.count == repos.count + 2,
            Array(components.prefix(repos.count)) == repos
        else { return nil }

        let segment = #/^[A-Za-z0-9_][A-Za-z0-9._-]*$/#
        for component in components.suffix(2) where component.wholeMatch(of: segment) == nil {
            return nil
        }
        return target
    }

    private static func reject(_ field: String, _ request: BrokerRequest) -> Result<
        BrokerAction, BrokerRejection
    > {
        let value =
            switch field {
            case "name": request.name ?? ""
            case "model": request.model ?? ""
            default: request.effort ?? ""
            }
        let kind = request.kind ?? ""
        return .failure(BrokerRejection(reason: "\(kind) \(field) '\(value)' refused"))
    }
}
