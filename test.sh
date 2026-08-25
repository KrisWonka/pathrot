#!/usr/bin/env bash
# Tests for pathrot. Uses the PATHROT_FAKE seam so nothing touches the network.
#
#   ./test.sh
#
# Verdict characters in a fake pattern: . = ok, ! = corrupt, ~ = timeout.
# Probes consume the pattern in order across rounds, wrapping at the end, so
# with -q (6 samples/round) a 12-character pattern controls rounds 2 and 3 and
# then repeats for round 4.

set -uo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

# expect_exit <code> <desc> <cmd...>
expect_exit() {
  local want=$1 desc=$2; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" -eq "$want" ]; then ok "$desc"; else bad "$desc" "exit $got, wanted $want"; fi
  LAST_OUT=$out
}

# expect_out <needle> <desc>   (checks LAST_OUT from the previous expect_exit)
expect_out() {
  case "$LAST_OUT" in
    *"$1"*) ok "$2" ;;
    *)      bad "$2" "output did not contain: $1" ;;
  esac
}

echo "pathrot tests"
echo

echo "─ interface selection"
# phys_iface must never hand back a tunnel, even when the default route is one.
. /dev/stdin <<< "$(sed -n '/^# The physical interface/,/^}$/p' pathrot)"
IFACE=$(phys_iface)
case "$IFACE" in
  utun*|tun*|tap*|wg*|tailscale*|feth*) bad "phys_iface skips tunnels" "returned '$IFACE'" ;;
  "")                                   bad "phys_iface finds an interface" "returned empty" ;;
  *)                                    ok  "phys_iface returned a physical interface ($IFACE)" ;;
esac
echo

echo "─ clean path"
expect_exit 0 "exits 0 when nothing is corrupted" env PATHROT_FAKE='............' ./pathrot -q
expect_out "path looks clean" "reports a clean verdict"
echo

echo "─ corrupting path, burst-triggered"
expect_exit 1 "exits 1 when uploads are corrupted" env PATHROT_FAKE='..!.!.......' ./pathrot -q
expect_out "this path is corrupting your uploads" "reports a corrupting verdict"
expect_out "burst-triggered" "classifies as burst-triggered when the slow round is clean"
expect_out "both destinations affected" "rules out the peer when both endpoints fail"
expect_out "Tunnel out" "recommends tunnelling"
echo

echo "─ corrupting path, constant"
expect_exit 1 "exits 1 when corruption survives rate-limiting" env PATHROT_FAKE='!.....' ./pathrot -q
expect_out "constant" "classifies as constant when the slow round still fails"
echo

echo "─ timeouts are not corruption"
# '~' is a timeout: a slow link, not a damaged one. Must still exit 0.
expect_exit 0 "a timing-out but clean link is not reported as corrupting" \
  env PATHROT_FAKE='~...~.......' ./pathrot -q
expect_out "path looks clean" "timeouts do not trigger a corruption verdict"
echo

echo "─ cli"
expect_exit 0 "--help exits 0" ./pathrot --help
expect_out "USAGE" "help mentions usage"
expect_exit 0 "--version exits 0" ./pathrot --version
expect_exit 2 "unknown flag exits 2" ./pathrot --nope
echo

echo "─ json"
expect_exit 1 "json mode still signals via exit code" env PATHROT_FAKE='..!.!.......' ./pathrot -q --json
expect_out '"verdict":"corrupting"' "json carries the verdict"
echo

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
