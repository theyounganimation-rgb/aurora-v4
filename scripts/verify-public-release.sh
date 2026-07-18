#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

typeset -a public_candidates packaging_candidates scan_candidates
typeset -A seen_candidates

public_candidates=("${(@f)$(git ls-files --cached --others --exclude-standard)}")
if (( ${#public_candidates} == 0 )); then
  print -u2 "public release scan requires a staged, committed, or untracked source tree"
  exit 1
fi

# Release packaging copies these paths directly, even when a local ignore rule
# would otherwise hide one of their files from Git. Scan the exact compilation
# inputs whenever the packager invokes this verifier.
if [[ "${AURORA_SCAN_PACKAGING_INPUTS:-0}" == "1" ]]; then
  packaging_candidates=(
    "${(@f)$(find Sources Resources -type f -print 2>/dev/null | LC_ALL=C sort)}"
    Package.swift
    scripts/render-icon.swift
    scripts/source-fingerprint.sh
  )
fi

for candidate in "${public_candidates[@]}" "${packaging_candidates[@]}"; do
  [[ -n "$candidate" && -f "$candidate" ]] || continue
  [[ -n "${seen_candidates[$candidate]:-}" ]] && continue
  seen_candidates[$candidate]=1
  scan_candidates+=("$candidate")
done

forbidden_paths="$({
  for candidate in "${public_candidates[@]}"; do
    print -r -- "$candidate"
  done
} | grep -E '(^|/)(\.env($|\.)|\.build/|dist/|website/)|\.(app|ipa|zip|p12|pem|key|mobileprovision|provisionprofile|xcarchive)(/|$)' \
    | grep -v -E '(^|/)\.env\.example$' \
    || true)"
if [[ -n "$forbidden_paths" ]]; then
  print -u2 "public release contains forbidden private or packaged paths:"
  print -u2 -r -- "$forbidden_paths"
  exit 1
fi

is_scanner_fixture() {
  case "$1" in
    scripts/verify-public-release.sh|scripts/verify-public-release-regressions.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

scan_content() {
  local label="$1"
  local pattern="$2"
  local candidate first_match line_number index_matches
  typeset -a working_hits index_hits

  # Inspect the bytes that are actually on disk. Report only location metadata;
  # echoing the matching line would turn a detection into a credential leak.
  for candidate in "${scan_candidates[@]}"; do
    is_scanner_fixture "$candidate" && continue
    first_match="$(LC_ALL=C grep -I -n -m 1 -E "$pattern" -- "$candidate" 2>/dev/null || true)"
    [[ -n "$first_match" ]] || continue
    line_number="${first_match%%:*}"
    [[ "$line_number" == <-> ]] || line_number="?"
    working_hits+=("$candidate:$line_number [working tree]")
  done

  # Also inspect the staged bytes so an already-staged secret cannot be hidden
  # by replacing the working-tree copy with a clean file before a commit.
  index_matches="$(git grep --cached -l -I -E "$pattern" -- . \
    ':(exclude)scripts/verify-public-release.sh' \
    ':(exclude)scripts/verify-public-release-regressions.sh' \
    2>/dev/null || true)"
  if [[ -n "$index_matches" ]]; then
    index_hits=("${(@f)index_matches}")
  fi

  if (( ${#working_hits} > 0 || ${#index_hits} > 0 )); then
    print -u2 "public release contains $label (matched values are intentionally redacted):"
    for candidate in "${working_hits[@]}"; do
      print -u2 -r -- "  $candidate"
    done
    for candidate in "${index_hits[@]}"; do
      [[ -n "$candidate" ]] && print -u2 -r -- "  $candidate [index]"
    done
    exit 1
  fi
}

scan_content \
  "personal machine, signing, or private-network identifiers" \
  '/Users/[A-Za-z0-9._-]+/|[A-Za-z0-9.-]+\.ts\.net|fd7a:115c:a1e0|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|Apple Development:[^[:space:]]*@[A-Za-z0-9.-]+'

scan_content \
  "credential-like literals" \
  'sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'

print "Public release scan passed."
