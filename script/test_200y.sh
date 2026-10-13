#!/usr/bin/env bash
# Run the WHOLE luv_locker suite against luv_locker_200y.
#
# luv_locker_200y is luv_locker with one constant changed (MAX_LOCK_DURATION 3,650 -> 73,050
# days). Rather than keep a second copy of every test, this checks that claim mechanically:
#   1. the two sources differ only in the name, the header comment and the horizon;
#   2. a scratch copy of the repo has each test import luv_locker_200y under the name
#      luv_locker, and the full suite runs against it.
# Extra args go to forge test (e.g. FOUNDRY_PROFILE=fork FORK_TEST=1 ... for the fork suite).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

norm() {
  sed -e 's/\bluv_locker_200y\b/luv_locker/g' "$1" |
    grep -v -e '^//' -e '^ \* @title' -e '^    ///' -e 'MAX_LOCK_DURATION = '
}
if ! diff <(norm src/luv_locker.sol) <(norm src/luv_locker_200y.sol) >/dev/null; then
  echo "luv_locker_200y.sol differs from luv_locker.sol beyond the horizon:" >&2
  diff <(norm src/luv_locker.sol) <(norm src/luv_locker_200y.sol) >&2 || true
  exit 1
fi
grep -q 'MAX_LOCK_DURATION = 3650 days;' src/luv_locker.sol
grep -q 'MAX_LOCK_DURATION = 73_050 days;' src/luv_locker_200y.sol
echo "source: luv_locker_200y = luv_locker except MAX_LOCK_DURATION (3650 -> 73_050 days)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r src test foundry.toml remappings.txt "$tmp/"
ln -s "$here/lib" "$tmp/lib"
rm "$tmp/test/luv_locker_200y.t.sol"
n=0
for f in "$tmp"/test/*.sol; do
  if grep -q 'import {luv_locker} from "../src/luv_locker.sol";' "$f"; then
    sed -i 's|import {luv_locker} from "../src/luv_locker.sol";|import {luv_locker_200y as luv_locker} from "../src/luv_locker_200y.sol";|' "$f"
    n=$((n + 1))
  fi
done
echo "suite: $n test files now import luv_locker_200y"
cd "$tmp" && forge test "$@"
