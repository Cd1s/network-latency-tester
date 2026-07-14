#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

# shellcheck source=../lib/state.sh
source "$ROOT_DIR/lib/state.sh"
# shellcheck source=../lib/bootstrap.sh
source "$ROOT_DIR/lib/bootstrap.sh"
# shellcheck source=../lib/network.sh
source "$ROOT_DIR/lib/network.sh"

TEST_TMP=$(mktemp -d)
ORIGINAL_PATH="$PATH"
trap 'PATH="$ORIGINAL_PATH"; rm -rf "$TEST_TMP"' EXIT

failures=0

assert_equal() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "ok - $description"
    else
        echo "not ok - $description (expected $expected, got $actual)"
        failures=$((failures + 1))
    fi
}

assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ok - $description"
    else
        echo "not ok - $description (missing: $needle)"
        failures=$((failures + 1))
    fi
}

make_mock() {
    local name="$1"
    local body="$2"

    printf '#!/bin/sh\n%s\n' "$body" > "$TEST_TMP/$name"
    chmod +x "$TEST_TMP/$name"
}

link_command() {
    local name="$1"
    ln -s "$(command -v "$name")" "$TEST_TMP/$name"
}

make_mock python3 '
[ "${MOCK_TELEGRAM_EMPTY:-false}" = "true" ] && exit 0
printf "%s\n" "203.0.113.1|DC1" "203.0.113.2|DC2"
'
make_mock ping '
case "$*" in
    *203.0.113.1*) avg=40.5; loss=0 ;;
    *203.0.113.2*) avg=12.4; loss=33 ;;
    *) exit 1 ;;
esac
printf "3 packets transmitted, 3 received, %s%% packet loss, time 1000ms\n" "$loss"
printf "rtt min/avg/max/mdev = 10.0/%s/50.0/1.0 ms\n" "$avg"
'
link_command sed
link_command head

PATH="$TEST_TMP"
export PATH
OS_TYPE="linux"

telegram_output_file="$TEST_TMP/telegram.out"
test_telegram_in_fping >"$telegram_output_file" 2>&1
telegram_status=$?

assert_equal "Telegram ping fallback succeeds" 0 "$telegram_status"
assert_equal "fastest Telegram node is cached" "203.0.113.2" "$TELEGRAM_BEST_IP"
assert_equal "Telegram DC is cached" "DC2" "$TELEGRAM_BEST_DC"
assert_equal "Telegram latency is cached" "12.0" "$TELEGRAM_BEST_LATENCY"
assert_equal "Telegram packet loss is cached" "33%" "$TELEGRAM_BEST_LOSS"

MOCK_TELEGRAM_EMPTY=true
export MOCK_TELEGRAM_EMPTY
test_telegram_in_fping >"$telegram_output_file" 2>&1
assert_equal "missing Telegram nodes clear the cached IP" "" "$TELEGRAM_BEST_IP"
assert_equal "missing Telegram nodes clear the cached loss" "0%" "$TELEGRAM_BEST_LOSS"
MOCK_TELEGRAM_EMPTY=false
export MOCK_TELEGRAM_EMPTY

quick_output=$(show_fping_results 2>&1)
quick_status=$?

assert_equal "quick test skip remains successful without fping" 0 "$quick_status"
assert_contains "quick test explains the ping fallback" "$quick_output" "后续真实连接测试将使用系统 ping"

PATH="$ORIGINAL_PATH"

if [[ "$failures" -ne 0 ]]; then
    echo "$failures test(s) failed"
    exit 1
fi

echo "all network fallback tests passed"
