#!/usr/bin/env bats
# Session context persistence tests.
#
# With ZMX_RESTORE set, each daemon periodically writes <session>.json into
# ZMX_RESTORE_DIR (default: $ZMX_DIR/restore) with the context needed to
# skeleton the session back after a reboot. Intentional session ends (shell
# exit, zmx kill) delete the file; a killed daemon (crash, reboot) leaves it
# behind for restore.

load test_helper

RESTORE_DIR() { echo "$ZMX_DIR/restore"; }

# Portable mtime (GNU stat -c, BSD stat -f). GNU must come first: BSD-style
# `stat -f %m` is a filesystem query to GNU stat, which succeeds with output
# that includes changing free-space counters.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

wait_for_file() {
  local path="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    [[ -f "$path" ]] && return 0
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for file '$path'" >&2
  return 1
}

wait_for_no_file() {
  local path="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    [[ ! -f "$path" ]] && return 0
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for file '$path' to disappear" >&2
  return 1
}

@test "capture: state file appears with session name and cwd" {
  cd "$BATS_TEST_TMPDIR"
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-capture -d sleep 30
  wait_for_session test-restore-capture

  local state="$(RESTORE_DIR)/test-restore-capture.json"
  wait_for_file "$state"

  run cat "$state"
  [[ "$output" == *'"name": "test-restore-capture"'* ]]
  [[ "$output" == *'"version": 1'* ]]
  # macOS resolves /tmp to /private/tmp, so compare the tail of the path.
  [[ "$output" == *"${BATS_TEST_TMPDIR#/private}"* ]]
}

@test "capture: no state file when ZMX_RESTORE is unset" {
  "$ZMX" run test-restore-off -d sleep 30
  wait_for_session test-restore-off

  sleep 2
  [[ ! -f "$(RESTORE_DIR)/test-restore-off.json" ]]
}

@test "capture: unchanged context is not rewritten" {
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-idle -d sleep 30
  wait_for_session test-restore-idle

  local state="$(RESTORE_DIR)/test-restore-idle.json"
  wait_for_file "$state"

  # The first ticks can rewrite as the foreground process settles; only then
  # is the context expected to hold still.
  sleep 2

  local before after
  before=$(mtime "$state")
  sleep 2.5
  after=$(mtime "$state")
  [[ "$before" == "$after" ]]
}

@test "lifecycle: zmx kill deletes the state file" {
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-kill -d sleep 30
  wait_for_session test-restore-kill

  local state="$(RESTORE_DIR)/test-restore-kill.json"
  wait_for_file "$state"

  "$ZMX" kill test-restore-kill
  wait_for_no_file "$state"
}

@test "lifecycle: shell exit deletes the state file" {
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-exit -d sleep 1
  wait_for_session test-restore-exit

  local state="$(RESTORE_DIR)/test-restore-exit.json"
  wait_for_file "$state"

  # Task-mode bash outlives the task; make the shell itself exit.
  printf 'exit\r' | "$ZMX" send test-restore-exit
  wait_for_no_file "$state" 10
}

# SIGKILL a session's daemon and shell to simulate a crash/reboot: no cleanup
# code runs, so the state file survives and the socket goes stale.
crash_session() {
  local name="$1" pid daemon_pid
  pid=$("$ZMX" list | grep -F "name=$name" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
  [[ -n "$pid" ]]
  daemon_pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  [[ -n "$daemon_pid" ]]
  kill -9 "$daemon_pid" "$pid" 2>/dev/null || true
  sleep 0.5
}

@test "lifecycle: killed daemon leaves the state file for restore" {
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-crash -d sleep 30
  wait_for_session test-restore-crash

  local state="$(RESTORE_DIR)/test-restore-crash.json"
  wait_for_file "$state"

  crash_session test-restore-crash
  [[ -f "$state" ]]
}

@test "restore: recreates a detached session in the cached cwd" {
  local dir="$BATS_TEST_TMPDIR/restore cwd"
  mkdir -p "$dir"
  cd "$dir"
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-again -d sleep 30
  wait_for_session test-restore-again
  wait_for_file "$(RESTORE_DIR)/test-restore-again.json"
  crash_session test-restore-again

  run "$ZMX" restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"restored session test-restore-again"* ]]

  wait_for_session test-restore-again
  wait_for_cwd test-restore-again "${dir// /%20}"
}

@test "restore: pre-types the captured command only with ZMX_RESTORE_CMD" {
  # `set -m` gives the task shell job control, so the command runs in its own
  # process group and is visible as the pty's foreground process.
  printf 'set -m\nsleep 30\n' | ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-type -d

  wait_for_session test-restore-type
  local state="$(RESTORE_DIR)/test-restore-type.json"
  wait_for_file "$state"
  # Give the foreground command a couple of capture ticks to land.
  local i=0
  while (( i < 50 )) && ! grep -qF '"cmd": "sleep 30"' "$state"; do sleep 0.1; (( i++ )) || true; done
  grep -qF '"cmd": "sleep 30"' "$state" || skip "foreground command not captured on this platform"
  crash_session test-restore-type

  ZMX_RESTORE_CMD=1 run "$ZMX" restore
  wait_for_session test-restore-type
  wait_for_output test-restore-type "sleep 30"
}

@test "restore: does not pre-type without ZMX_RESTORE_CMD" {
  printf 'set -m\nsleep 30\n' | ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-notype -d
  wait_for_session test-restore-notype
  local state="$(RESTORE_DIR)/test-restore-notype.json"
  wait_for_file "$state"
  local i=0
  while (( i < 50 )) && ! grep -qF '"cmd": "sleep 30"' "$state"; do sleep 0.1; (( i++ )) || true; done
  grep -qF '"cmd": "sleep 30"' "$state" || skip "foreground command not captured on this platform"
  crash_session test-restore-notype

  run "$ZMX" restore
  wait_for_session test-restore-notype

  sleep 1
  run "$ZMX" history test-restore-notype
  [[ "$output" != *"sleep 30"* ]]
}

@test "auto-restore: zmx list repopulates when no sessions are alive" {
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-auto -d sleep 30
  wait_for_session test-restore-auto
  wait_for_file "$(RESTORE_DIR)/test-restore-auto.json"
  crash_session test-restore-auto

  ZMX_RESTORE=1 run "$ZMX" list
  [[ "$output" == *"restored session test-restore-auto"* ]]
  wait_for_session test-restore-auto
}

@test "auto-restore: zmx list --short never restores" {
  ZMX_RESTORE=1 ZMX_RESTORE_INTERVAL=1 "$ZMX" run test-restore-short -d sleep 30
  wait_for_session test-restore-short
  wait_for_file "$(RESTORE_DIR)/test-restore-short.json"
  crash_session test-restore-short

  ZMX_RESTORE=1 run "$ZMX" list --short
  [[ "$output" != *"test-restore-short"* ]]
  run "$ZMX" list --short
  [[ "$output" != *"test-restore-short"* ]]
}

@test "restore: reports when the cache is empty" {
  run "$ZMX" restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cached sessions found"* ]]
}

@test "save: writes state on demand, without ZMX_RESTORE" {
  "$ZMX" run test-save-one -d sleep 30
  wait_for_session test-save-one
  [[ ! -f "$(RESTORE_DIR)/test-save-one.json" ]]

  run "$ZMX" save test-save-one
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved session test-save-one"* ]]
  [[ -f "$(RESTORE_DIR)/test-save-one.json" ]]
  grep -qF '"name": "test-save-one"' "$(RESTORE_DIR)/test-save-one.json"
}

@test "save: no name saves every live session" {
  "$ZMX" run test-save-a -d sleep 30
  "$ZMX" run test-save-b -d sleep 30
  wait_for_session test-save-a
  wait_for_session test-save-b

  run "$ZMX" save
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved session test-save-a"* ]]
  [[ "$output" == *"saved session test-save-b"* ]]
  [[ -f "$(RESTORE_DIR)/test-save-a.json" ]]
  [[ -f "$(RESTORE_DIR)/test-save-b.json" ]]
}

@test "save: manually saved session still cleans up on kill" {
  "$ZMX" run test-save-kill -d sleep 30
  wait_for_session test-save-kill
  "$ZMX" save test-save-kill
  [[ -f "$(RESTORE_DIR)/test-save-kill.json" ]]

  "$ZMX" kill test-save-kill
  wait_for_no_file "$(RESTORE_DIR)/test-save-kill.json"
}

@test "save: errors for a missing session" {
  run "$ZMX" save test-save-missing
  [ "$status" -ne 0 ]
}
