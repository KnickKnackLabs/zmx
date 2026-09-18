#!/usr/bin/env bats
# Public run-path regressions. No Glow, real user profile, or prompt matching.

load test_helper

prepare_startup_home() {
  mkdir -m 700 "$BATS_TEST_TMPDIR/home"
  cp "$REPO_DIR/test/fixtures/startup-reader.bash" "$BATS_TEST_TMPDIR/home/.bash_profile"
  printf 'startup\ncommand\n' > "$BATS_TEST_TMPDIR/expected-events"
  startup_env=(env -i
    HOME="$BATS_TEST_TMPDIR/home"
    PATH=/usr/bin:/bin
    TERM=xterm-256color
    ZMX_DIR="$ZMX_DIR"
    ZMX_STARTUP_TEST_DIR="$BATS_TEST_TMPDIR")
}

assert_startup_then_command() {
  # A missing completion must be bounded: on the broken implementation the
  # profile consumes both the command and zmx's appended completion marker.
  run timeout 5 "$ZMX" wait startup
  local completion_status="$status"
  if [[ -f "$BATS_TEST_TMPDIR/consumed-input" ]]; then
    printf 'Bytes consumed during login: %s\n' "$(wc -c < "$BATS_TEST_TMPDIR/consumed-input")"
  fi
  printf 'Command completion status: %s\n' "$completion_status"

  # File effects cannot be satisfied by PTY echo. Exact contents prove startup
  # finished first and the command ran once, rather than being retried.
  run diff -u "$BATS_TEST_TMPDIR/expected-events" "$BATS_TEST_TMPDIR/events"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$completion_status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/consumed-input" ]
}

@test "run: command executes once after ordinary login startup" {
  prepare_startup_home

  run timeout 10 "${startup_env[@]}" "$ZMX" run startup -d \
    bash -c 'printf "command\n" >> "$ZMX_STARTUP_TEST_DIR/events"'
  [ "$status" -eq 0 ]
  assert_startup_then_command
}

@test "run: login terminal reader cannot consume the submitted command" {
  prepare_startup_home
  touch "$BATS_TEST_TMPDIR/read-terminal"

  run timeout 10 "${startup_env[@]}" "$ZMX" run startup -d \
    bash -c 'printf "command\n" >> "$ZMX_STARTUP_TEST_DIR/events"'
  [ "$status" -eq 0 ]
  assert_startup_then_command
}
