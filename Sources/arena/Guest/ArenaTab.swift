import Foundation

/// `arena-tab`, the one command a sandboxed agent has for reaching Herdr. See ADR-010.
///
/// Shipped through `ToolCache` rather than the image. The image is the repository's own
/// (ADR-004), so arena cannot rely on anything being in it, while the tool cache is mounted
/// read-only into every sandbox at a directory already on the agent's PATH. Embedded here
/// rather than as a SwiftPM resource, because `scripts/install.sh` installs the binary alone
/// and a resource bundle would not travel with it.
///
/// Bash rather than anything with a JSON library, because bash is the one interpreter every
/// image has: the agent itself runs under `bash -lc`.
enum ArenaTab {
    static let name = "arena-tab"
    static let guestPath = ToolCache.guestBin + "/" + name

    static let sandboxVariable = "ARENA_SANDBOX"
    static let workspaceVariable = "ARENA_HERDR_WORKSPACE"
    /// Set only on a child arena-tab started, so the seeded hooks know whose status to write.
    static let agentVariable = "ARENA_AGENT_NAME"

    /// Where the reader writes a child's brief, as the guest sees it. The brief travels as a
    /// file rather than in the command typed into the host pane, so text the guest wrote
    /// never passes through a host shell.
    static func guestBrief(_ name: String) -> String {
        "/var/lib/arena/agents/\(name)/brief.md"
    }

    /// The command each seeded hook runs, so `SandboxHome` can find its own entries again.
    static func hookCommand(_ event: String) -> String { "\(guestPath) hook \(event)" }

    static let script = #"""
        #!/usr/bin/env bash
        # Written by arena. Edits are overwritten on the next `arena new`. See ADR-010.
        set -euo pipefail

        state=/var/lib/arena
        agents=$state/agents

        die() { printf 'arena-tab: %s\n' "$*" >&2; exit 1; }

        usage() {
            cat <<'EOF'
        usage:
          arena-tab --name <name> [--label <text>] [--model <m>] [--effort <e>] [<brief>...]
          arena-tab --lane <branch> --name <name> [...] [<brief>...]
          arena-tab prompt <name> <text>
          arena-tab wait <name> [--timeout <seconds>]

        Without --lane the child is a second agent in this container and this worktree.
        With --lane the host cuts that lane and launches a new sandbox for it.
        A brief of `-`, or none while stdin is not a terminal, is read from stdin.

        A child reports through /var/lib/arena/agents/<name>/status (working, waiting,
        done) and /var/lib/arena/agents/<name>/last-message.md.
        EOF
        }

        valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; }

        # Control characters other than tab, newline and CR are dropped rather than escaped
        # as \u00XX; the host refuses a request it cannot decode, so this keeps it decodable.
        json_string() {
            local s
            s=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
            s=${s//\\/\\\\}
            s=${s//\"/\\\"}
            s=${s//$'\t'/\\t}
            s=${s//$'\r'/\\r}
            s=${s//$'\n'/\\n}
            printf '"%s"' "$s"
        }

        # A request with nobody to read it would sit in the directory forever, so fail here.
        inbox() {
            [[ -n ${ARENA_HERDR_WORKSPACE:-} ]] ||
                die "ARENA_HERDR_WORKSPACE is unset, so no host reader serves this sandbox. Only \`arena new --herdr\` starts one, and a --lane child gets none."
            [[ -n ${ARENA_SANDBOX:-} ]] || die "ARENA_SANDBOX is unset; this is not an arena sandbox."
            dir=$state/requests/$ARENA_SANDBOX
            [[ -d $dir ]] || die "$dir does not exist, so the host reader for $ARENA_SANDBOX is not running."
        }

        # Written to a dotfile and renamed, so the reader never sees half a request. The
        # reader deletes the request when it takes it and answers in <id>.result.
        submit() {
            local body=$1 limit=$2 id waited=0
            id=$(date +%s)-$$-$RANDOM
            printf '%s\n' "$body" >"$dir/.$id.tmp"
            mv "$dir/.$id.tmp" "$dir/$id.json"

            while [[ -f $dir/$id.json ]]; do
                if ((waited >= 15)); then
                    rm -f "$dir/$id.json"
                    die "the host reader for $ARENA_SANDBOX did not take the request within 15s; it is not running."
                fi
                sleep 1
                waited=$((waited + 1))
            done

            waited=0
            while [[ ! -f $dir/$id.result ]]; do
                ((waited < limit)) ||
                    die "the reader took the request but has not answered after ${limit}s. It may still be launching; check $agents/<name>/status."
                sleep 1
                waited=$((waited + 1))
            done

            local result
            result=$(cat "$dir/$id.result")
            rm -f "$dir/$id.result"
            printf 'arena-tab: %s\n' "$result"
            [[ $result == ok* ]]
        }

        cmd_spawn() {
            local lane='' name='' label='' model='' effort='' brief
            local -a words=()
            while (($#)); do
                case $1 in
                    --lane) lane=${2:?--lane needs a branch}; shift 2 ;;
                    --name) name=${2:?--name needs a value}; shift 2 ;;
                    --label) label=${2:?--label needs a value}; shift 2 ;;
                    --model) model=${2:?--model needs a value}; shift 2 ;;
                    --effort) effort=${2:?--effort needs a value}; shift 2 ;;
                    -h | --help) usage; exit 0 ;;
                    --) shift; words+=("$@"); break ;;
                    -) words+=(-); shift ;;
                    -*) die "unknown option $1" ;;
                    *) words+=("$1"); shift ;;
                esac
            done

            if [[ -z $name && -n $lane ]]; then name=${lane//\//-}; fi
            [[ -n $name ]] || die "--name is required; it is the handle for prompt and wait"
            valid_name "$name" || die "$name is not a valid name: letters, digits, '.', '_' and '-'"

            if ((${#words[@]} == 1)) && [[ ${words[0]} == - ]]; then
                brief=$(cat)
            elif ((${#words[@]} == 0)) && [[ ! -t 0 ]]; then
                brief=$(cat)
            elif ((${#words[@]})); then
                # Quoted: bash 3.2 word-splits an unquoted ${words[*]} even in an assignment.
                brief="${words[*]}"
            else
                brief=''
            fi

            inbox
            local body kind=shared limit=120
            [[ -z $lane ]] || { kind=lane; limit=1800; }
            body="{\"kind\":\"$kind\",\"name\":$(json_string "$name")"
            [[ -z $lane ]] || body+=",\"branch\":$(json_string "$lane")"
            [[ -z $label ]] || body+=",\"label\":$(json_string "$label")"
            [[ -z $model ]] || body+=",\"model\":$(json_string "$model")"
            [[ -z $effort ]] || body+=",\"effort\":$(json_string "$effort")"
            body+=",\"brief\":$(json_string "$brief")}"
            submit "$body" "$limit"
        }

        cmd_prompt() {
            (($# == 2)) || die "usage: arena-tab prompt <name> <text>"
            valid_name "$1" || die "$1 is not a valid name"
            inbox
            submit "{\"kind\":\"prompt\",\"name\":$(json_string "$1"),\"text\":$(json_string "$2")}" 60
        }

        cmd_wait() {
            local name=${1:?usage: arena-tab wait <name> [--timeout <seconds>]} timeout=0 waited=0 status
            shift
            if [[ ${1:-} == --timeout ]]; then timeout=${2:?--timeout needs seconds}; fi
            valid_name "$name" || die "$name is not a valid name"
            while :; do
                status=$(cat "$agents/$name/status" 2>/dev/null || true)
                case $status in
                    done | waiting)
                        printf '%s\n' "$status"
                        exit 0
                        ;;
                esac
                if ((timeout > 0 && waited >= timeout)); then
                    die "$name is still ${status:-unreported} after ${timeout}s"
                fi
                sleep 2
                waited=$((waited + 2))
            done
        }

        write_status() {
            printf '%s\n' "$2" >"$1/.status.tmp"
            mv "$1/.status.tmp" "$1/status"
        }

        # Claude Code puts the final reply in the Stop hook's input as last_assistant_message.
        # The transcript is the fallback for a version that does not.
        last_message() {
            local input=$1 message=''
            if command -v jq >/dev/null; then
                message=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
                if [[ -z $message ]]; then
                    local transcript
                    transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
                    if [[ -n $transcript && -f $transcript ]]; then
                        message=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // empty' "$transcript" 2>/dev/null || true)
                    fi
                fi
            elif command -v python3 >/dev/null; then
                message=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_assistant_message") or "")' 2>/dev/null || true)
            fi
            printf '%s' "$message"
        }

        # Seeded into every sandbox home, so it runs for agents arena-tab did not start.
        # Those have no ARENA_AGENT_NAME and are left alone. A Stop hook that exits 2 keeps
        # the agent running, so nothing here may.
        cmd_hook() {
            local event=${1:-} input
            input=$(cat || true)
            local name=${ARENA_AGENT_NAME:-}
            [[ -n $name ]] && valid_name "$name" || exit 0
            local dir=$agents/$name
            mkdir -p "$dir" || exit 0

            case $event in
                prompt) write_status "$dir" working ;;
                stop)
                    local message
                    message=$(last_message "$input")
                    if [[ -n $message ]]; then
                        printf '%s\n' "$message" >"$dir/.last-message.tmp"
                        mv "$dir/.last-message.tmp" "$dir/last-message.md"
                    fi
                    write_status "$dir" done
                    ;;
                notification)
                    # The idle reminder follows every finished turn; it must not turn done
                    # back into waiting.
                    if [[ $input == *'"idle_prompt"'* && $(cat "$dir/status" 2>/dev/null) == done ]]; then
                        exit 0
                    fi
                    write_status "$dir" waiting
                    ;;
            esac
            exit 0
        }

        case ${1:-} in
            prompt) shift; cmd_prompt "$@" ;;
            wait) shift; cmd_wait "$@" ;;
            hook) shift; cmd_hook "$@" || exit 0 ;;
            -h | --help | help) usage ;;
            *) cmd_spawn "$@" ;;
        esac
        """#
}
