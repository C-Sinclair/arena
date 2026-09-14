#!/usr/bin/env bash
# Every relative markdown link must resolve. Run from the repository root.
#
# Deliberately not a pipeline into `while`: that runs the loop in a subshell, where a
# non-zero exit is discarded and the check silently always passes.
set -uo pipefail

broken=0

while IFS= read -r file; do
    while IFS= read -r link; do
        case "$link" in http*|mailto:*) continue ;; esac
        target="$(dirname "$file")/${link%%#*}"
        if [ ! -e "$target" ]; then
            echo "::error file=$file::broken link to $link"
            broken=$((broken + 1))
        fi
    done < <(grep -oE '\]\([^)]+\)' "$file" | sed -E 's/^\]\(//; s/\)$//' | grep -v '^#')
done < <(git ls-files '*.md')

if [ "$broken" -ne 0 ]; then
    echo "$broken broken link(s)"
    exit 1
fi
echo "all markdown links resolve"
