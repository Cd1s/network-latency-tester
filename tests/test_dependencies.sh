#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

# shellcheck source=../lib/state.sh
source "$ROOT_DIR/lib/state.sh"
# shellcheck source=../lib/bootstrap.sh
source "$ROOT_DIR/lib/bootstrap.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

failures=0

fail() {
    echo "not ok - $1"
    failures=$((failures + 1))
}

pass() {
    echo "ok - $1"
}

assert_status() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description (expected $expected, got $actual)"
    fi
}

assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$description"
    else
        fail "$description (missing: $needle)"
    fi
}

assert_not_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$description (unexpected: $needle)"
    else
        pass "$description"
    fi
}

make_mock() {
    local directory="$1"
    local name="$2"
    local body="$3"

    printf '#!/bin/sh\n%s\n' "$body" > "$directory/$name"
    chmod +x "$directory/$name"
}

setup_mocks() {
    local directory="$1"
    local include_bc="$2"
    local command_name

    mkdir -p "$directory"
    for command_name in ping curl nslookup; do
        make_mock "$directory" "$command_name" 'exit 0'
    done
    if [[ "$include_bc" == "true" ]]; then
        make_mock "$directory" bc 'exit 0'
    fi
    make_mock "$directory" id '[ "$1" = "-u" ] && printf "%s\n" "${MOCK_UID:-0}"'
    make_mock "$directory" apt-get '
printf "%s\n" "$*" >> "$APT_LOG"
if [ "${APT_INSTALLS_BC:-false}" = "true" ] && [ "$*" = "install -y bc" ]; then
    printf "#!/bin/sh\nexit 0\n" > "$MOCK_BIN/bc"
    /bin/chmod +x "$MOCK_BIN/bc"
fi
exit "${APT_EXIT_CODE:-0}"
'
}

run_dependency_check() {
    local mock_path="$1"
    local uid="$2"
    local apt_exit_code="$3"
    local apt_installs_bc="${4:-false}"

    trap - EXIT
    export MOCK_UID="$uid"
    export APT_EXIT_CODE="$apt_exit_code"
    export APT_INSTALLS_BC="$apt_installs_bc"
    export MOCK_BIN="$mock_path"
    export APT_LOG="$mock_path/apt.log"
    PATH="$mock_path"
    export PATH

    set -e
    check_dependencies
}

test_successful_required_install() {
    local mock_path="$TEST_TMP/required-success"
    local output status

    setup_mocks "$mock_path" false
    output=$(run_dependency_check "$mock_path" 0 0 true 2>&1)
    status=$?

    assert_status "successful required dependency install continues" 0 "$status"
    assert_contains "successful required dependency install is reported" "$output" "所有依赖安装成功"
    assert_not_contains "successful required dependency install has no failure" "$output" "安装 bc失败"
}

test_optional_fping() {
    local uid="$1"
    local mock_path="$TEST_TMP/optional-$uid"
    local output status

    setup_mocks "$mock_path" true
    output=$(run_dependency_check "$mock_path" "$uid" 42 2>&1)
    status=$?

    assert_status "missing optional fping succeeds for uid $uid" 0 "$status"
    assert_contains "missing optional fping is reported for uid $uid" "$output" "建议安装 fping"
    assert_contains "required dependencies pass for uid $uid" "$output" "所有必要依赖已安装"
    assert_not_contains "optional fping does not trigger installation for uid $uid" "$output" "正在自动安装依赖"

    if [[ -s "$mock_path/apt.log" ]]; then
        fail "optional fping does not call apt-get for uid $uid"
    else
        pass "optional fping does not call apt-get for uid $uid"
    fi
}

test_failed_required_install() {
    local mock_path="$TEST_TMP/required-failure"
    local output status apt_calls

    setup_mocks "$mock_path" false
    output=$(run_dependency_check "$mock_path" 0 42 2>&1)
    status=$?
    apt_calls=$(<"$mock_path/apt.log")

    assert_status "failed required dependency install returns a controlled error" 1 "$status"
    assert_contains "apt update failure remains visible" "$output" "更新 APT 软件包索引失败"
    assert_contains "failed dependency is reported after installation" "$output" "部分依赖安装失败: bc"
    assert_contains "manual instructions are shown after installation failure" "$output" "手动安装说明"
    assert_contains "apt update was attempted" "$apt_calls" "update -qq"
    assert_contains "bc installation was attempted" "$apt_calls" "install -y bc"
}

test_optional_fping 0
test_optional_fping 1000
test_successful_required_install
test_failed_required_install

if [[ "$failures" -ne 0 ]]; then
    echo "$failures test(s) failed"
    exit 1
fi

echo "all dependency tests passed"
