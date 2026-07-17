#!/bin/zsh
set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" || "$ROOT" != /* || ! -d "$ROOT/Sources/Aurora" ]]
then
    print -u2 -- "usage: source-fingerprint.sh /absolute/path/to/aurora-source"
    exit 64
fi

ROOT="$(cd "$ROOT" && pwd -P)"
INPUTS=(
    Package.swift
    Resources/Aurora.entitlements
    Resources/Info.plist
    scripts/render-icon.swift
)

for input in $INPUTS
do
    [[ -f "$ROOT/$input" ]] || {
        print -u2 -- "source fingerprint input is missing: $input"
        exit 66
    }
done

# Hash relative names and file digests, rather than absolute paths or mtimes.
# The same frozen source snapshot therefore produces the same fingerprint in a
# temporary packaging directory and in the working checkout.
(
    cd "$ROOT"
    {
        print -l -- $INPUTS
        find Sources/Aurora -type f -print
    } | LC_ALL=C sort | while IFS= read -r relative_path
    do
        digest="$(shasum -a 256 "$relative_path" | awk '{print $1}')"
        print -r -- "$relative_path $digest"
    done
) | shasum -a 256 | awk '{print $1}'
