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

@test "control: answers split DA2, DSR, and CPR terminal queries" {
  run terminal_query_probe --mode control --session tq-split-da2 --chunk '\033[' --chunk '>c' --expect 1b5b3e313b31303b3063
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-split-da2x --chunk '\033[>' --chunk '0c' --expect 1b5b3e313b31303b3063
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-split-dsr --chunk '\033[' --chunk '5n' --expect 1b5b306e
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-split-cpr --chunk '\033[6' --chunk 'n' --expect-regex '1b5b[0-9]+3b[0-9]+52'
  assert_probe_ok
}

@test "control: answers batched terminal queries in order" {
  run terminal_query_probe --mode control --session tq-batched --chunk '\033[c\033[>c\033[5n' --expect 1b5b3f36323b3232631b5b3e313b31303b30631b5b306e
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-batched-cpr --chunk '\033[c\033[6n' --expect-regex '1b5b3f36323b3232631b5b[0-9]+3b[0-9]+52'
  assert_probe_ok
}

@test "control: answers queries without hiding surrounding output" {
  run terminal_query_probe --mode control --session tq-outq --chunk 'before\033[cafter' --expect 1b5b3f36323b323263 --expect-text before --expect-text after
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-outsplit --chunk 'before' --chunk '\033[' --chunk 'cafter' --expect 1b5b3f36323b323263 --expect-text before --expect-text after
  assert_probe_ok
}

@test "control: answers DSR status and CPR cursor queries" {
  run terminal_query_probe --mode control --session tq-dsr --query '\033[5n' --expect 1b5b306e
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-cpr --query '\033[6n' --expect-regex '1b5b[0-9]+3b[0-9]+52'
  assert_probe_ok
}

@test "control: ignores unsupported query-like CSI variants" {
  run terminal_query_probe --mode control --session tq-priv-dsr --query '\033[?6n' --expect ''
  assert_probe_ok

  run terminal_query_probe --mode control --session tq-da-param --query '\033[1c' --expect ''
  assert_probe_ok
}

@test "control: filters mixed supported and unsupported CSI query batches" {
  run terminal_query_probe --mode control --session tq-mix-csi --chunk '\033[?6n\033[c\033[1c\033[5n' --expect 1b5b3f36323b3232631b5b306e
  assert_probe_ok
}

@test "control: split unsupported CSI prefix does not block later valid query" {
  run terminal_query_probe --mode control --session tq-split-unsup --chunk '\033[?' --chunk '6n\033[c' --expect 1b5b3f36323b323263
  assert_probe_ok
}

@test "control: repeated unsupported CSI bursts do not block later queries" {
  run terminal_query_probe --mode control --session tq-unsup-burst --chunk '\033[?6n\033[1c\033[?6n\033[c\033[6n' --expect-regex '1b5b3f36323b3232631b5b[0-9]+3b[0-9]+52'
  assert_probe_ok
}

@test "control: split unsupported CSI with output does not hide text or later query" {
  run terminal_query_probe --mode control --session tq-unsup-out --chunk 'pre\033[?' --chunk '6nmid\033[cpost' --expect 1b5b3f36323b323263 --expect-text pre --expect-text mid --expect-text post
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
