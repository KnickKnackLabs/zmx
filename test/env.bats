#!/usr/bin/env bats
# Environment validation before attach, and actual attach/daemon/print-env flow.

load test_helper

@test "attach rejects malformed tracked names before creating a session" {
  local name
  for name in '2BAD' 'A-B' 'A B' 'A=B' 'X;touch injected;#'; do
    run env ZMX_TRACK_ENV="$name" "$ZMX" attach env-invalid
    [ "$status" -eq 1 ]
    [[ "$output" == *'tracked environment names must match'* ]]
  done
  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "attach rejects newline values before forwarding or logging them" {
  local value
  for value in $'env-private-canary\nINJECTED=value' $'env-private-canary\rvalue'; do
    run env ZMX_TRACK_ENV=DISPLAY DISPLAY="$value" "$ZMX" attach env-invalid
    [ "$status" -eq 1 ]
    [[ "$output" == *'tracked environment values cannot contain'* ]]
    [[ "$output" != *'env-private-canary'* ]]
  done
  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -R -F 'env-private-canary' "$ZMX_DIR"
}

@test "environment round trip quotes shell syntax, omits value logs and rejects invalid peers" {
  run timeout 15 python3 "$BATS_TEST_DIRNAME/fixtures/env_forwarding.py" "$ZMX" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}
