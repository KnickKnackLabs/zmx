#!/usr/bin/env bats
# Curated tail/wait status and aggregation regressions for tricky session
# completion, tailing, and prompt-drain behavior.

load test_helper

assert_ok_or_dump() {
  if [ "$status" -ne 0 ]; then
    echo "status=$status" >&3
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}

assert_status_or_dump() {
  local expected="$1"
  if [ "$status" -ne "$expected" ]; then
    echo "expected status=$expected actual=$status" >&3
    echo "$output" >&3
  fi
  [ "$status" -eq "$expected" ]
}

start_task() {
  local name="$1" delay="$2" marker="$3" exit_code="$4"
  "$ZMX" run "$name" -d python3 -c "import os,time,sys; time.sleep($delay); os.write(1,b'$marker\\n'); sys.exit($exit_code)"
  wait_for_session "$name"
}

settle_tasks() {
  timeout 6 "$ZMX" wait "$@" >/dev/null 2>&1 || true
}

@test "tail: waits for all active sessions with mixed exits" {
  start_task tmix-ok 0.25 TAIL_MIXED_OK 0
  start_task tmix-f 0.55 TAIL_MIXED_FAIL 49

  run timeout 8 "$ZMX" tail tmix-ok tmix-f
  assert_status_or_dump 49
  [[ "$output" == *"TAIL_MIXED_OK"* ]]
  [[ "$output" == *"TAIL_MIXED_FAIL"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:0"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:49"* ]]
}

@test "tail: waits for all active sessions when all succeed" {
  start_task tall-a 0.25 TAIL_ALL_OK_A 0
  start_task tall-b 0.55 TAIL_ALL_OK_B 0

  run timeout 8 "$ZMX" tail tall-a tall-b
  assert_ok_or_dump
  [[ "$output" == *"TAIL_ALL_OK_A"* ]]
  [[ "$output" == *"TAIL_ALL_OK_B"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:0"* ]]
}

@test "tail: waits for slower success after earlier failure" {
  start_task tfail 0.25 TAIL_FAIL_FIRST 42
  start_task tlate 0.65 TAIL_SUCCESS_LATER 0

  run timeout 8 "$ZMX" tail tfail tlate
  assert_status_or_dump 42
  [[ "$output" == *"TAIL_FAIL_FIRST"* ]]
  [[ "$output" == *"TAIL_SUCCESS_LATER"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:42"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:0"* ]]
}

@test "tail: handles three active sessions with mixed exits" {
  start_task t3-ok-a 0.20 TAIL_THREE_OK_A 0
  start_task t3-fail 0.45 TAIL_THREE_FAIL 47
  start_task t3-ok-b 0.70 TAIL_THREE_OK_B 0

  run timeout 9 "$ZMX" tail t3-ok-a t3-fail t3-ok-b
  assert_status_or_dump 47
  [[ "$output" == *"TAIL_THREE_OK_A"* ]]
  [[ "$output" == *"TAIL_THREE_FAIL"* ]]
  [[ "$output" == *"TAIL_THREE_OK_B"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:47"* ]]
}

@test "wait: waits for all active sessions with mixed exits" {
  start_task wmix-ok 0.25 WAIT_MIXED_OK 0
  start_task wmix-f 0.55 WAIT_MIXED_FAIL 43

  run timeout 8 "$ZMX" wait wmix-ok wmix-f
  assert_status_or_dump 43
  [[ "$output" == *"wmix-ok completed"* ]]
  [[ "$output" == *"wmix-f exited (43)"* ]]
  [[ "$output" == *"tasks failed"* ]]
}

@test "wait: waits for all active sessions when all succeed" {
  start_task wall-a 0.25 WAIT_ALL_OK_A 0
  start_task wall-b 0.55 WAIT_ALL_OK_B 0

  run timeout 8 "$ZMX" wait wall-a wall-b
  assert_ok_or_dump
  [[ "$output" == *"wall-a completed"* ]]
  [[ "$output" == *"wall-b completed"* ]]
  [[ "$output" == *"all tasks completed"* ]]
}

@test "wait: waits for slower success after earlier failure" {
  start_task wfail 0.25 WAIT_FAIL_FIRST 44
  start_task wlate 0.65 WAIT_SUCCESS_LATER 0

  run timeout 8 "$ZMX" wait wfail wlate
  assert_status_or_dump 44
  [[ "$output" == *"wfail exited (44)"* ]]
  [[ "$output" == *"wlate completed"* ]]
  [[ "$output" == *"tasks failed"* ]]
}

@test "tail: late completed sessions return remembered status without replay" {
  start_task tl-a 0.10 TAIL_LATE_FAIL_A 41
  start_task tl-b 0.15 TAIL_LATE_FAIL_B 42
  settle_tasks tl-a tl-b

  run timeout 5 "$ZMX" tail tl-a tl-b
  if [ "$status" -ne 41 ] && [ "$status" -ne 42 ]; then
    echo "expected status 41 or 42 actual=$status" >&3
    echo "$output" >&3
    false
  fi
  [[ "$output" != *"TAIL_LATE_FAIL_A"* ]]
  [[ "$output" != *"TAIL_LATE_FAIL_B"* ]]
  [[ "$output" != *"ZMX_TASK_COMPLETED"* ]]
}

@test "wait: late completed sessions report remembered status" {
  start_task wl-ok 0.10 WAIT_LATE_OK 0
  start_task wl-f 0.15 WAIT_LATE_FAIL 45
  settle_tasks wl-ok wl-f

  run timeout 5 "$ZMX" wait wl-ok wl-f
  assert_status_or_dump 45
  [[ "$output" == *"wl-ok completed"* ]]
  [[ "$output" == *"wl-f exited (45)"* ]]
  [[ "$output" == *"tasks failed"* ]]
}

@test "tail: completed plus running sessions combine remembered status with live output" {
  start_task td-f 0.10 TAIL_DONE_FAIL 46
  settle_tasks td-f
  start_task tr-ok 0.45 TAIL_RUNNING_OK 0

  run timeout 8 "$ZMX" tail td-f tr-ok
  assert_status_or_dump 46
  [[ "$output" == *"TAIL_RUNNING_OK"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:0"* ]]
  [[ "$output" != *"TAIL_DONE_FAIL"* ]]
}

@test "wait: completed plus running sessions combine remembered status with live wait" {
  start_task wd-f 0.10 WAIT_DONE_FAIL 46
  settle_tasks wd-f
  start_task wr-ok 0.45 WAIT_RUNNING_OK 0

  run timeout 8 "$ZMX" wait wd-f wr-ok
  assert_status_or_dump 46
  [[ "$output" == *"wd-f exited (46)"* ]]
  [[ "$output" == *"wr-ok completed"* ]]
  [[ "$output" == *"tasks failed"* ]]
}

@test "tail: wildcard active sessions with mixed exits" {
  start_task ptt-ok 0.25 PREFIX_TAIL_OK 0
  start_task ptt-fail 0.55 PREFIX_TAIL_FAIL 48

  run timeout 8 "$ZMX" tail 'ptt-*'
  assert_status_or_dump 48
  [[ "$output" == *"PREFIX_TAIL_OK"* ]]
  [[ "$output" == *"PREFIX_TAIL_FAIL"* ]]
  [[ "$output" == *"ZMX_TASK_COMPLETED:48"* ]]
}

@test "wait: wildcard active sessions with mixed exits" {
  start_task pwt-ok 0.25 PREFIX_WAIT_OK 0
  start_task pwt-fail 0.55 PREFIX_WAIT_FAIL 48

  run timeout 8 "$ZMX" wait 'pwt-*'
  assert_status_or_dump 48
  [[ "$output" == *"pwt-ok completed"* ]]
  [[ "$output" == *"pwt-fail exited (48)"* ]]
}

@test "wait: ZMX_SESSION_PREFIX fallback with mixed exits" {
  start_task ew-ok 0.25 ENV_WAIT_OK 0
  start_task ew-f 0.55 ENV_WAIT_FAIL 49

  run timeout 8 env ZMX_SESSION_PREFIX=ew- "$ZMX" wait
  assert_status_or_dump 49
  [[ "$output" == *"ew-ok completed"* ]]
  [[ "$output" == *"ew-f exited (49)"* ]]
}

@test "tail: no-argument ZMX_SESSION_PREFIX remains an explicit unsupported entry path" {
  start_task egap-one 0.25 ENV_TAIL_GAP 0

  run timeout 5 env ZMX_SESSION_PREFIX=egap- "$ZMX" tail
  [ "$status" -ne 0 ]
  [[ "$output" != *"ENV_TAIL_GAP"* ]]
}

@test "run: drains immediate zsh precmd output after task completion marker" {
  if [ ! -x /bin/zsh ]; then
    skip "/bin/zsh is required for this prompt-drain regression"
  fi

  run timeout 8 env SHELL=/bin/zsh "$ZMX" run pm-zsh eval "precmd(){ printf '\\033[36mPOST_MARKER_PRECMD\\033[0m'; }; false"
  assert_status_or_dump 1

  marker_index=$(printf '%s' "$output" | awk 'BEGIN{idx=-1} {pos=index($0,"ZMX_TASK_COMPLETED:1"); if (pos && idx < 0) idx=length(prefix)+pos; prefix=prefix $0 "\n"} END{print idx}')
  prompt_index=$(printf '%s' "$output" | awk 'BEGIN{idx=-1} {pos=index($0,"POST_MARKER_PRECMD"); if (pos && idx < 0) idx=length(prefix)+pos; prefix=prefix $0 "\n"} END{print idx}')

  if [ "$marker_index" -lt 0 ] || [ "$prompt_index" -le "$marker_index" ]; then
    echo "marker_index=$marker_index prompt_index=$prompt_index" >&3
    echo "$output" >&3
    false
  fi
}
