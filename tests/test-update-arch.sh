#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL_RM=$(command -v rm)
TEMP_DIR=$(mktemp -d)
MOCK_SOURCE="$ROOT_DIR/tests/mock-command.sh"
SCRIPT_TERMINAL_TOOL=$(command -v script)
PASS_COUNT=0

cleanup() {
  "$REAL_RM" -rf "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [[ -n "${RUN_OUTPUT:-}" ]]; then
    printf '%s\n' '--- updater output ---' "$RUN_OUTPUT" >&2
  fi
  exit 1
}

assert_contains() {
  [[ "$RUN_OUTPUT" == *"$2"* ]] || fail "$1: expected output to contain: $2"
}

assert_not_contains() {
  [[ "$RUN_OUTPUT" != *"$2"* ]] || fail "$1: unexpected output: $2"
}

assert_call_count() {
  local expected=$1 command_name=$2 first_argument=$3 actual
  actual=$(awk -F '\t' -v name="$command_name" -v argument="$first_argument" \
    '$1 == name && $2 == argument { count++ } END { print count + 0 }' "$TEST_CALL_LOG")
  [[ "$actual" == "$expected" ]] || fail "expected $expected $command_name $first_argument call(s), got $actual"
}

assert_call_line() {
  local expected=$1
  "$GREP" -Fqx -- "$expected" "$TEST_CALL_LOG" || fail "expected call: $expected"
}

prepare_case() {
  local name=$1
  CASE_DIR="$TEMP_DIR/$name"
  MOCK_BIN="$CASE_DIR/bin"
  BASE_BIN="$CASE_DIR/base-bin"
  TEST_CALL_LOG="$CASE_DIR/calls.log"
  mkdir -p "$MOCK_BIN" "$BASE_BIN"
  cp "$ROOT_DIR/update-arch.sh" "$CASE_DIR/update-arch.sh"
  cp "$MOCK_SOURCE" "$MOCK_BIN/mock-command"
  chmod +x "$MOCK_BIN/mock-command"
  : > "$TEST_CALL_LOG"
  touch "$CASE_DIR/.acknowledged-lock"

  for command_name in sudo pacman rm systemd-inhibit sleep systemctl; do
    ln -s mock-command "$MOCK_BIN/$command_name"
  done
  for command_name in bash readlink dirname mkdir date tee awk sort mktemp touch; do
    ln -s "$(command -v "$command_name")" "$BASE_BIN/$command_name"
  done

  export CASE_DIR MOCK_BIN BASE_BIN TEST_CALL_LOG
  export TEST_REAL_RM="$REAL_RM"
  export TEST_PACMAN_MODE=success TEST_AUR_MODE=success
  export TEST_PACMAN_ORPHANS= TEST_AUR_ORPHANS=
  export TEST_REFLECTOR=false
}

add_helper() {
  ln -s mock-command "$MOCK_BIN/$1"
}

run_updater() {
  local arguments=${1:-}
  if ! RUN_OUTPUT=$(PATH="$MOCK_BIN:$BASE_BIN" "$SCRIPT_TERMINAL_TOOL" -q -e -c \
    "bash \"$CASE_DIR/update-arch.sh\" $arguments" /dev/null 2>&1); then
    fail "updater exited unsuccessfully (arguments: $arguments)"
  fi
}

run_updater_with_input() {
  local input=$1
  if ! RUN_OUTPUT=$(printf '%s\n' "$input" | PATH="$MOCK_BIN:$BASE_BIN" \
    "$SCRIPT_TERMINAL_TOOL" -q -e -c "bash \"$CASE_DIR/update-arch.sh\"" /dev/null 2>&1); then
    fail 'updater exited unsuccessfully while handling reboot input'
  fi
}

pass() {
  ((PASS_COUNT += 1))
  printf 'ok %d - %s\n' "$PASS_COUNT" "$1"
}

GREP=$(command -v grep)

prepare_case help
run_updater --help
assert_contains 'help' 'Usage:'
assert_call_count 0 pacman -Sy
pass 'help exits before running update commands'

prepare_case success
run_updater --no-reboot
assert_call_count 1 pacman -Syu
assert_contains 'success summary' 'Official repository packages: 2'
assert_contains 'success summary' 'Packages ignored by pacman due to dependency breaks: none'
assert_contains 'success without Flatpak' 'flatpak is not installed; skipping Flatpak update.'
assert_contains 'success without reflector' 'reflector.service not found; skipping service start.'
assert_not_contains 'success' 'FAILED:'
pass 'successful update and package summary'

prepare_case pacman-dependency-retry
TEST_PACMAN_MODE=dependency
export TEST_PACMAN_MODE
run_updater --no-reboot
assert_call_count 2 pacman -Syu
assert_call_line $'pacman\t-Syu\t--noconfirm\t--ignore\tblocked-one,blocked-two'
assert_contains 'pacman retry summary' 'Packages ignored by pacman due to dependency breaks: blocked-one blocked-two'
assert_not_contains 'pacman retry' 'FAILED: Updating system packages'
pass 'pacman retries once with all unique dependency-breaking packages'

prepare_case pacman-other-failure
TEST_PACMAN_MODE=failure
export TEST_PACMAN_MODE
run_updater --no-reboot
assert_call_count 1 pacman -Syu
assert_contains 'pacman failure' 'FAILED: Updating system packages'
assert_contains 'pacman failure summary' 'Packages ignored by pacman due to dependency breaks: none'
pass 'pacman does not retry unrelated failures'

prepare_case yay-dependency-retry
add_helper yay
TEST_AUR_MODE=dependency
TEST_PACMAN_ORPHANS=system-orphan
TEST_AUR_ORPHANS=aur-orphan
TEST_REFLECTOR=true
export TEST_AUR_MODE TEST_PACMAN_ORPHANS TEST_AUR_ORPHANS TEST_REFLECTOR
add_helper flatpak
run_updater --no-reboot
assert_call_count 2 yay -Syu
assert_call_line $'yay\t-Syu\t--noconfirm\t--ignore\taur-blocked-one,aur-blocked-two'
assert_contains 'yay retry summary' 'Packages ignored by yay due to dependency breaks: aur-blocked-one aur-blocked-two'
assert_call_line $'pacman\t-Rns\t--noconfirm\tsystem-orphan'
assert_call_line $'yay\t-Rns\t--noconfirm\taur-orphan'
assert_call_line $'flatpak\tupdate\t--noninteractive'
assert_call_line $'systemctl\tstart\treflector.service'
pass 'yay retry, orphan cleanup, Flatpak, and reflector branches'

prepare_case aur-other-failure
add_helper yay
TEST_AUR_MODE=failure
export TEST_AUR_MODE
run_updater --no-reboot
assert_call_count 1 yay -Syu
assert_contains 'AUR failure' 'FAILED: Updating AUR packages'
assert_contains 'AUR failure summary' 'Packages ignored by AUR helper due to dependency breaks: none'
pass 'AUR helper does not retry unrelated failures'

prepare_case paru-success
add_helper paru
run_updater --no-reboot
assert_call_count 1 paru -Syu
assert_contains 'paru summary' 'AUR packages: 1'
pass 'paru is selected and updated when installed alone'

prepare_case both-helpers
add_helper yay
add_helper paru
run_updater --no-reboot
assert_call_count 0 yay -Syu
assert_call_count 0 paru -Syu
assert_contains 'multiple helpers' 'Multiple AUR helpers are installed; skipping AUR update.'
pass 'multiple installed AUR helpers are skipped'

prepare_case dry-run
add_helper yay
add_helper flatpak
TEST_REFLECTOR=true
export TEST_REFLECTOR
run_updater --dry-run
assert_call_count 0 sudo -v
assert_call_count 0 pacman -Syu
assert_call_count 0 yay -Syu
assert_call_count 0 flatpak update
assert_call_count 0 systemctl start
assert_contains 'dry run' '[DRY RUN] sudo pacman -Syu --noconfirm'
assert_contains 'dry run' '[DRY RUN] yay -Syu --noconfirm'
assert_contains 'dry run' 'Dry run complete. No system changes were made'
pass 'dry-run prints update actions without executing them'

prepare_case reboot-no
run_updater_with_input n
assert_contains 'reboot prompt' 'Would you like to reboot now?'
assert_contains 'reboot declined' 'Reboot skipped by user.'
assert_call_count 0 sudo reboot
pass 'default reboot prompt accepts a no response'

prepare_case reboot-yes
run_updater_with_input y
assert_contains 'reboot accepted' 'Rebooting now...'
assert_call_count 1 sudo reboot
pass 'default reboot prompt accepts a yes response'

prepare_case first-run-warning
"$REAL_RM" -f "$CASE_DIR/.acknowledged-lock"
run_updater --no-reboot
assert_contains 'first-run warning' 'By running this script, you are granting it permission'
[[ -e "$CASE_DIR/.acknowledged-lock" ]] || fail 'first-run warning lock was not created'
assert_call_count 1 sudo -v
pass 'first-run warning and sudo credential check'

printf 'All %d updater tests passed.\n' "$PASS_COUNT"