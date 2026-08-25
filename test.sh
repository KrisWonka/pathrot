#!/usr/bin/env bash
# Tests for pathrot. Uses the PATHROT_FAKE seam so nothing touches the network.
#
#   ./test.sh
#
# Verdict characters in a fake pattern:
#   .  ok        !  corrupt (TLS integrity error)
#   r  reset     ~  timeout        i  invalid (endpoint ignored the body)
#
# Probes consume the pattern in order across rounds, wrapping at the end, so
# with -q (6 samples/round) a 12-character pattern drives rounds 2 and 3 and
# then repeats for round 4.

set -uo pipefail
cd "$(dirname "$0")" || exit 2

PASS=0; FAIL=0
LAST_OUT=""

ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
        [ $# -gt 1 ] && printf '       %s\n' "$2"; }

expect_exit() {           # expect_exit <code> <desc> <cmd...>
  local want=$1 desc=$2; shift 2
  LAST_OUT=$("$@" 2>&1); local got=$?
  if [ "$got" -eq "$want" ]; then ok "$desc"; else bad "$desc" "exit $got, wanted $want"; fi
}

expect_out() {            # expect_out <needle> <desc>
  case "$LAST_OUT" in
    *"$1"*) ok "$2" ;;
    *)      bad "$2" "output did not contain: $1" ;;
  esac
}

expect_no_out() {         # expect_no_out <needle> <desc>
  case "$LAST_OUT" in
    *"$1"*) bad "$2" "output unexpectedly contained: $1" ;;
    *)      ok "$2" ;;
  esac
}

echo "pathrot tests"
echo

echo "─ interface selection"
# phys_iface must never hand back a tunnel, even when the default route is one.
. /dev/stdin <<< "$(sed -n '/^phys_iface()/,/^}$/p' pathrot)"
IFACE=$(phys_iface)
case "$IFACE" in
  utun*|tun*|tap*|wg*|tailscale*|feth*) bad "phys_iface skips tunnels" "returned '$IFACE'" ;;
  "")                                   bad "phys_iface finds an interface" "returned empty" ;;
  *)                                    ok  "phys_iface returned a physical interface ($IFACE)" ;;
esac
echo

echo "─ clean path"
expect_exit 0 "exits 0 when nothing fails" env PATHROT_FAKE='............' ./pathrot -q
expect_out "path looks clean" "reports a clean verdict"
echo

echo "─ corruption, burst-triggered"
expect_exit 1 "exits 1 on TLS integrity failures" env PATHROT_FAKE='..!.!.......' ./pathrot -q
expect_out "this path is corrupting your uploads" "names it corruption"
expect_out "burst-triggered" "classifies burst-triggered when the slow round is clean"
expect_out "both destinations affected" "rules out the peer when both endpoints fail"
expect_out "Tunnel out" "recommends tunnelling"
echo

echo "─ corruption, constant"
expect_exit 1 "exits 1 when failures survive rate-limiting" env PATHROT_FAKE='!.....' ./pathrot -q
expect_out "constant" "classifies constant when the slow round still fails"
echo

echo "─ bare resets must not be reported as clean"
# The regression that mattered: a dropped connection whose TLS library does not
# name the cause is exactly the ECONNRESET this tool exists to explain. It must
# never come out as a clean bill of health.
expect_exit 1 "exits 1 on bare resets with no TLS error" env PATHROT_FAKE='..r.r.......' ./pathrot -q
expect_out "dropping your uploads" "reports dropping, not corrupting"
expect_out "cause not confirmed" "is honest that the cause is unproven"
expect_no_out "path looks clean" "does not call a resetting path clean"
echo

echo "─ an endpoint that ignores the body must abort, not pass"
# rc=0 with a 404 uploads only part of the payload. Counting that as a healthy
# probe would make pathrot tell a person with a rotten link that they are fine.
expect_exit 2 "exits 2 when probes are invalid" env PATHROT_FAKE='iiiiiiiiiiii' ./pathrot -q
expect_out "stopped consuming the body" "explains the endpoint is unusable"
expect_no_out "path looks clean" "never claims clean off invalid probes"

# The same guard, over the real network, on the baseline check rather than the
# fake seam: google.com answers 405 to a POST after reading only part of it.
if [ "${PATHROT_SKIP_NET:-0}" = 0 ]; then
  expect_exit 2 "exits 2 against a real endpoint that refuses the body" \
    env PATHROT_URL=https://www.google.com/ ./pathrot -q
  expect_out "did not accept the full" "baseline check names the unusable endpoint"
else
  echo "  skip network tests (PATHROT_SKIP_NET=1)"
fi
echo

echo "─ timeouts are not corruption"
expect_exit 0 "a slow but undamaged link is not reported as failing" \
  env PATHROT_FAKE='~...~.......' ./pathrot -q
expect_out "path looks clean" "timeouts alone do not trigger a verdict"
expect_out "timed out" "still mentions the timeouts"
echo

echo "─ cli"
expect_exit 0 "--help exits 0" ./pathrot --help
expect_out "USAGE" "help mentions usage"
expect_exit 0 "--version exits 0" ./pathrot --version
expect_exit 2 "unknown flag exits 2" ./pathrot --nope
expect_exit 2 "non-numeric --samples exits 2" ./pathrot -n abc
echo

echo "─ json"
expect_exit 1 "json mode still signals via exit code" env PATHROT_FAKE='..!.!.......' ./pathrot -q --json
expect_out '"verdict":"corrupting"' "json carries the verdict"
expect_out '"corrupt":2' "json separates confirmed corruption"
expect_exit 1 "json for a resetting path" env PATHROT_FAKE='..r.r.......' ./pathrot -q --json
expect_out '"verdict":"dropping"' "json distinguishes dropping from corrupting"
echo

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
