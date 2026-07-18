#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SCANNER="$ROOT/scripts/verify-public-release.sh"
WORK_ROOT="$(mktemp -d /private/tmp/aurora-public-scan.XXXXXX)"
REPO="$WORK_ROOT/repo"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM HUP

fail() {
  print -u2 -- "Public release scanner regression failed: $*"
  exit 1
}

mkdir -p "$REPO/scripts" "$REPO/Sources" "$REPO/Resources"
install -m 755 "$SCANNER" "$REPO/scripts/verify-public-release.sh"
cd "$REPO"
git init -q
git config user.email "scanner-regression@example.invalid"
git config user.name "Aurora scanner regression"
print "safe public source" > README.md
print "safe source" > Sources/main.txt
git add README.md Sources/main.txt scripts/verify-public-release.sh
git commit -q -m "clean fixture"
./scripts/verify-public-release.sh >/dev/null

# Construct the fake value at runtime so this regression never places a
# credential-shaped literal in Aurora's own public source.
fake_secret="sk-proj-$(printf 'A%.0s' {1..32})"
print -r -- "token=$fake_secret" >> README.md
if dirty_output="$(./scripts/verify-public-release.sh 2>&1)"; then
  fail "a dirty tracked credential was accepted"
fi
[[ "$dirty_output" == *"README.md"* ]] || fail "dirty failure omitted the source path"
[[ "$dirty_output" == *"redacted"* ]] || fail "dirty failure omitted the redaction notice"
[[ "$dirty_output" != *"$fake_secret"* ]] || fail "dirty failure echoed the detected value"
git restore README.md

print "Sources/private-fixture.txt" > .gitignore
git add .gitignore
git commit -q -m "ignore packaging fixture"
print -r -- "token=$fake_secret" > Sources/private-fixture.txt
if package_output="$(AURORA_SCAN_PACKAGING_INPUTS=1 ./scripts/verify-public-release.sh 2>&1)"; then
  fail "an ignored packaging credential was accepted"
fi
[[ "$package_output" == *"Sources/private-fixture.txt"* ]] || \
  fail "packaging failure omitted the source path"
[[ "$package_output" != *"$fake_secret"* ]] || \
  fail "packaging failure echoed the detected value"
rm -f Sources/private-fixture.txt

./scripts/verify-public-release.sh >/dev/null
print "Public release scanner regressions passed."
