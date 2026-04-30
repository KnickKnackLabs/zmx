#!/usr/bin/env bats
# Terminal-query behavior for tail-only and control clients.

load test_helper

terminal_query_probe() {
  env ZMX="$ZMX" ZMX_DIR="$ZMX_DIR" python3 "$REPO_DIR/test/terminal_query_probe.py" "$@"
}

assert_probe_ok() {
  if [ "$status" -ne 0 ]; then
    echo "status=$status" >&3
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}

@test "control: answers DA1 and DA2 terminal queries" {
  run terminal_query_probe --mode control --session tq-da1 --query '\033[c' --expect 1b5b3f36323b323263
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-da2 --query '\033[>c' --expect 1b5b3e313b31303b3063
  assert_probe_ok
}

@test "control: answers explicit DA1 and DA2 terminal queries" {
  run terminal_query_probe --mode control --session tq-da1x --query '\033[0c' --expect 1b5b3f36323b323263
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-da2x --query '\033[>0c' --expect 1b5b3e313b31303b3063
  assert_probe_ok
}

@test "run: answers DA1 split across PTY output reads" {
  run terminal_query_probe --mode run --session tq-split --split --expect 1b5b3f36323b323263
  assert_probe_ok
}

@test "control: answers DSR status and CPR cursor queries" {
  run terminal_query_probe --mode control --session tq-dsr --query '\033[5n' --expect 1b5b306e
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-cpr --query '\033[6n' --expect-regex '1b5b[0-9]+3b[0-9]+52'
  assert_probe_ok
}

@test "run: detached terminal client does not suppress later DA responses" {
  # A real attach initializes terminal-client state. Ctrl-\ detaches it.
  python3 - "$ZMX" "$ZMX_DIR" <<'PY'
import os, pty, select, subprocess, sys, time
zmx, zmx_dir = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["ZMX_DIR"] = zmx_dir
master, slave = pty.openpty()
proc = subprocess.Popen([zmx, "attach", "tq-sticky"], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
os.close(slave)
deadline = time.time() + 2
while time.time() < deadline:
    readable, _, _ = select.select([master], [], [], 0.05)
    if readable:
        try:
            os.read(master, 4096)
        except OSError:
            break
    if proc.poll() is not None:
        break
os.write(master, b"\x1c")
proc.wait(timeout=3)
os.close(master)
PY

  wait_for_session tq-sticky
  run terminal_query_probe --mode run --session tq-sticky --query '\033[c' --expect 1b5b3f36323b323263
  assert_probe_ok
}
