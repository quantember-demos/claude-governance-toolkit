#!/usr/bin/env bash
# Run every test suite; exit non-zero if any fails. A suite that cannot run
# (missing node or jq) is reported as SKIPPED, never as passed.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
status=0
skipped=()
echo "== workflow (node --test)"
if command -v node >/dev/null; then
  out="$(node --test "$REPO/workflows/dna-zipper.test.mjs" 2>&1)" || status=1
  grep -E "^# (tests|pass|fail)|^not ok" <<<"$out"
else
  echo "SKIPPED: node not installed"; skipped+=(workflow)
fi
for t in test_hooks.sh test_scripts.sh test_install.sh; do
  echo "== $t"
  out="$("$REPO/tests/$t" 2>&1)" || status=1
  echo "$out"
  grep -q '^SKIP:' <<<"$out" && skipped+=("$t")
done
if (( status != 0 )); then
  echo "FAILURES (see above)"
elif (( ${#skipped[@]} )); then
  echo "PASSED, but ${#skipped[@]} suite(s) did not run: ${skipped[*]}"
else
  echo "ALL PASSED"
fi
exit "$status"
