#!/usr/bin/env bats
# End-to-end tests for the binary zmx-control/v1 adapter lane.

load test_helper

write_byte() {
  printf '%b' "\\$(printf '%03o' "$1")"
}

write_control_frame() {
  local tag="$1" payload="$2" len="${#2}"
  write_byte "$tag"
  write_byte $((len & 255))
  write_byte $(((len >> 8) & 255))
  write_byte $(((len >> 16) & 255))
  write_byte $(((len >> 24) & 255))
  printf '%s' "$payload"
}

assert_control_frames() {
  od -An -v -tu1 "$1" | awk '
    { for (i = 1; i <= NF; i++) bytes[++count] = $i }
    END {
      cursor = 1
      frames = 0
      while (cursor <= count) {
        if (count - cursor + 1 < 5) exit 1
        tag = bytes[cursor]
        if (tag != 1 && tag != 8 && tag != 14 && tag != 15 && tag != 16 && tag != 17) exit 1
        len = bytes[cursor + 1] + 256 * bytes[cursor + 2] + 65536 * bytes[cursor + 3] + 16777216 * bytes[cursor + 4]
        cursor += 5 + len
        if (cursor > count + 1) exit 1
        frames++
      }
      if (cursor != count + 1 || frames == 0) exit 1
    }
  '
}

@test "control: probe advertises the stable protocol" {
  run "$ZMX" control --probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"protocol=zmx-control/v1"* ]]
  [[ "$output" == *"tier=control"* ]]
}

@test "control: current daemon returns an initial viewport" {
  "$ZMX" run control-viewport -d echo control-viewport-marker
  wait_for_session control-viewport
  wait_for_output control-viewport control-viewport-marker

  local frames="$BATS_TEST_TMPDIR/control-viewport.frames"
  run bash -c '
    timeout 5 "$0" control --rows 24 --cols 80 control-viewport </dev/null >"$1"
    grep -aqF control-viewport-marker "$1"
  ' "$ZMX" "$frames"
  [ "$status" -eq 0 ]
  assert_control_frames "$frames"
}

@test "control: framed input reaches an existing session" {
  "$ZMX" run control-input -d echo ready
  wait_for_session control-input
  wait_for_output control-input ready

  export -f write_byte write_control_frame
  run bash -c '
    {
      write_control_frame 0 $'"'"'echo control-input-marker\r'"'"'
      write_control_frame 3 ""
    } | timeout 5 "$0" control --rows 24 --cols 80 control-input >/dev/null
  ' "$ZMX"
  [ "$status" -eq 0 ]

  wait_for_output control-input control-input-marker
}

@test "control: command-on-create drains immediate output" {
  local frames="$BATS_TEST_TMPDIR/control-create.frames"
  run bash -c '
    timeout 5 "$0" control --rows 24 --cols 80 control-create \
      /bin/sh -c "printf control-create-marker" </dev/null >"$1"
    grep -aqF control-create-marker "$1"
  ' "$ZMX" "$frames"
  [ "$status" -eq 0 ]
  assert_control_frames "$frames"
}
