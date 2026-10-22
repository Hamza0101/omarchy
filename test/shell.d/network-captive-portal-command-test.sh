#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin"

# Every external effect is stubbed and logged: the real exit node, browser,
# NetworkManager and notifications are never touched.
stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$stage/bin/$1"
  chmod +x "$stage/bin/$1"
}
stub tailscale 'printf "%s\n" "$TEST_TAILSCALE_STATUS"'
stub curl 'printf "curl %s\n" "${@: -1}" >> "$TEST_LOG"; exit "${TEST_CURL_STATUS:-0}"'
stub omarchy-launch-browser 'printf "browser %s\n" "$*" >> "$TEST_LOG"'
stub omarchy-notification-send 'printf "notify %s\n" "$*" >> "$TEST_LOG"'
stub sleep ':'
# Reports a portal for the first TEST_NMCLI_PORTAL_CHECKS checks (two by
# default), then full connectivity.
stub nmcli 'count=$(( $(cat "$TEST_NMCLI_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$count" > "$TEST_NMCLI_COUNT"; if (( count > ${TEST_NMCLI_PORTAL_CHECKS:-2} )); then echo full; else echo portal; fi'

run_portal() {
  rm -f "$stage/log" "$stage/count"
  TEST_LOG="$stage/log" TEST_NMCLI_COUNT="$stage/count" XDG_RUNTIME_DIR="$stage" TEST_TAILSCALE_STATUS="$1" TEST_CURL_STATUS="${2:-0}" \
    PATH="$stage/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-network-captive-portal" "http://ping.omacom.io/nm-check.txt"
}

toggle="http://local-tailscaled.sock/localapi/v0/set-use-exit-node-enabled"

run_portal '{"ExitNodeStatus":{"ID":"node","Online":true}}'
expected="curl $toggle?enabled=false
notify -g 󰒊 Tailscale exit node paused It comes back once you're signed in
browser http://ping.omacom.io/nm-check.txt
curl $toggle?enabled=true
notify -g 󰒊 Tailscale exit node restored"
[[ $(<"$stage/log") == "$expected" ]] || fail "pauses the exit node, opens the portal, and restores it once online" "$(<"$stage/log")"
pass "pauses the exit node, opens the portal, and restores it once online"
[[ $(<"$stage/count") == 3 ]] || fail "re-checks until connectivity is full, then stops" "$(<"$stage/count")"
pass "re-checks until connectivity is full, then stops"

run_portal '{"ExitNodeStatus":null}'
[[ $(<"$stage/log") == "browser http://ping.omacom.io/nm-check.txt" ]] || fail "leaves Tailscale alone without an exit node" "$(<"$stage/log")"
pass "leaves Tailscale alone without an exit node"

run_portal '{"ExitNodeStatus":{"ID":"node","Online":true}}' 1
[[ $(<"$stage/log") == "curl $toggle?enabled=false
browser http://ping.omacom.io/nm-check.txt" ]] || fail "does not restore an exit node it failed to pause" "$(<"$stage/log")"
pass "does not restore an exit node it failed to pause"

# Well past the old ten-minute cap: the exit node stays paused until online.
TEST_NMCLI_PORTAL_CHECKS=400 run_portal '{"ExitNodeStatus":{"ID":"node","Online":true}}'
[[ $(<"$stage/count") == 401 ]] || fail "keeps checking through a slow sign-in" "$(<"$stage/count")"
[[ $(tail -1 "$stage/log") == "notify -g 󰒊 Tailscale exit node restored" ]] || fail "restores the exit node only once a slow sign-in completes" "$(<"$stage/log")"
pass "keeps the exit node paused until a slow sign-in completes"

# A second click while the first is still watching only reopens the portal.
exec 8>"$stage/omarchy-network-captive-portal.lock"
flock -n 8
run_portal '{"ExitNodeStatus":{"ID":"node","Online":true}}'
exec 8>&-
[[ $(<"$stage/log") == "browser http://ping.omacom.io/nm-check.txt" ]] || fail "a second click only reopens the portal" "$(<"$stage/log")"
pass "a second click only reopens the portal"
