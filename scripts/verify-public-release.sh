#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

tracked_files="$(git ls-files)"
if [[ -z "$tracked_files" ]]; then
  print -u2 "public release scan requires a staged or committed source tree"
  exit 1
fi

forbidden_paths="$(
  print -r -- "$tracked_files" \
    | grep -E '(^|/)(\.env($|\.)|\.build/|dist/|website/)|\.(app|ipa|zip|p12|pem|key|mobileprovision|provisionprofile|xcarchive)(/|$)' \
    | grep -v -E '(^|/)\.env\.example$' \
    || true
)"
if [[ -n "$forbidden_paths" ]]; then
  print -u2 "public release contains forbidden private or packaged paths:"
  print -u2 -r -- "$forbidden_paths"
  exit 1
fi

scan_content() {
  local label="$1"
  local pattern="$2"
  local matches
  matches="$(
    git grep --cached -n -I -E "$pattern" -- . \
      ':(exclude)scripts/verify-public-release.sh' \
      || true
  )"
  if [[ -n "$matches" ]]; then
    print -u2 "public release contains $label:"
    print -u2 -r -- "$matches"
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
