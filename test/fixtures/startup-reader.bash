# Sourced as .bash_profile in a disposable HOME, not in the caller's shell.
# A bounded terminal read models welcome programs that query /dev/tty during
# login startup. Record consumed input without evaluating any of it.
if [[ -f "$ZMX_STARTUP_TEST_DIR/read-terminal" ]]; then
  startup_input=
  if IFS= read -r -t 2 startup_input </dev/tty; then
    :
  fi
  printf '%s' "$startup_input" > "$ZMX_STARTUP_TEST_DIR/consumed-input"
  unset startup_input
fi
printf 'startup\n' >> "$ZMX_STARTUP_TEST_DIR/events"
PS1='startup-test$ '
