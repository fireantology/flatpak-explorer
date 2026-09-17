#!/usr/bin/env bash
# Runs the QML test suite. This is the only supported way in: it puts the fake
# `flatpak` on PATH and sets the marker the harness checks before it will run
# anything, because some of these tests call install/uninstall/repair and would
# otherwise hit your real Flatpak installation.
#
# Usage: ./run-tests.sh [-v]
#   -v  show everything quickshell prints, not just the test lines
#
# Two passes: the main suite against the stub, then a second process with no
# flatpak on PATH at all, which is the only way to exercise the "flatpak is not
# installed" path (PATH is fixed when the process starts).
set -uo pipefail
# The harness ends its run by SIGTERMing itself (quickshell honours neither
# Qt.exit() nor Qt.quit()), so each pass is launched through a plain `sh`
# that exits 0 afterwards -- otherwise bash announces every pass as
# "Terminated: <the whole pipeline>". The verdict is read from the output.

cd "$(dirname "$0")" || exit 1
repo=$PWD

verbose=0
case "${1:-}" in
  -v|--verbose) verbose=1 ;;
  "") ;;
  *) echo "usage: $0 [-v]" >&2; exit 2 ;;
esac

# Resolved now, as absolute paths: the missing-flatpak pass runs with a PATH
# that would not find these two either.
quickshell_bin=$(type -P quickshell) || { echo "quickshell is not on PATH" >&2; exit 2; }
timeout_bin=$(type -P timeout) || { echo "timeout is not on PATH" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
control="$tmp/scenario"
argvlog="$tmp/argv.log"
printf 'default' > "$control"
: > "$argvlog"

# A PATH with the handful of tools the harness itself needs and no flatpak, for
# the second pass.
mkdir -p "$tmp/nopath"
for bin in sh kill cat head; do
  src=$(type -P "$bin") || { echo "cannot find $bin" >&2; exit 2; }
  ln -sf "$src" "$tmp/nopath/$bin"
done

total_passed=0
total_failed=0

run_pass() {
  local mode=$1 path=$2 out="$tmp/$1.log"

  printf '\n=== %s pass ===\n' "$mode"
  PATH="$path" \
  FLATPAK_EXPLORER_TEST_STUB=1 \
  FLATPAK_EXPLORER_TEST_MODE="$mode" \
  FLATPAK_EXPLORER_TEST_CONTROL="$control" \
  FLATPAK_EXPLORER_TEST_LOG="$argvlog" \
    "$timeout_bin" 180 sh -c '"$1" --no-color -p "$2"; exit 0' sh "$quickshell_bin" "$repo/tests.qml" 2>&1 \
    | sed -u 's/^[[:space:]]*\(DEBUG\|WARN\|INFO\|ERROR\)[[:space:]]*qml:[[:space:]]*//' \
    | tee "$out" \
    | { if [ "$verbose" = 1 ]; then cat; else grep -E '^ *(ok |FAIL |-- |== |running |REFUSING|ERROR)' || true; fi }

  local line passed failed
  line=$(grep -F '__TESTS__' "$out" | tail -1)
  if [ -z "$line" ]; then
    echo "  FAIL the $mode pass produced no result line -- it crashed, hung, or refused to start"
    echo "       full output: $out (rerun with -v to see it live)"
    total_failed=$((total_failed + 1))
    return
  fi
  passed=$(printf '%s' "$line" | sed -n 's/.*passed=\([0-9]*\).*/\1/p')
  failed=$(printf '%s' "$line" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')
  total_passed=$((total_passed + ${passed:-0}))
  total_failed=$((total_failed + ${failed:-0}))
}

run_pass main "$repo/tests/stub:$PATH"
run_pass missing "$tmp/nopath"

printf '\n=== %d passed, %d failed ===\n' "$total_passed" "$total_failed"
[ "$total_failed" -eq 0 ]
