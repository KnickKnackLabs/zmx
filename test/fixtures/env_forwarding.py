"""Exercise public attach and print-env using a private PTY, home and socket dir."""
import os
from pathlib import Path
import pty
import socket
import struct
import subprocess
import sys
import time

zmx, root_arg = sys.argv[1:]
root = Path(root_arg)
home = root / "env-home"
home.mkdir(mode=0o700)
socket_dir = os.environ["ZMX_DIR"]
value = "env-private-canary: it's $(touch injected); `touch injected` \\ = \t café"
env = {
    "HOME": str(home),
    "PATH": os.defpath,
    "TERM": "xterm-256color",
    "ZMX_DIR": socket_dir,
    "ZMX_TRACK_ENV": "ZMXTEST_VALUE,ZMXTEST_EMPTY,ZMXTEST_UNSET",
    "ZMXTEST_VALUE": value,
    "ZMXTEST_EMPTY": "",
}


def cli(*args):
    return subprocess.run(
        [zmx, *args], env=env, cwd=root, capture_output=True, timeout=3
    )


def print_env(*args):
    result = cli("print-env", *args)
    assert result.returncode == 0, result.stderr
    return result.stdout


master, slave = pty.openpty()
attach = subprocess.Popen(
    [zmx, "attach", "env-roundtrip", "/bin/sleep", "30"],
    env=env, cwd=root, stdin=slave, stdout=slave, stderr=slave,
)
os.close(slave)
try:
    # The reply proves the public attach path forwarded EnvSet and became leader.
    expected = f"ZMXTEST_VALUE={value}\nZMXTEST_EMPTY=\n-ZMXTEST_UNSET\n".encode()
    deadline = time.monotonic() + 5
    while True:
        result = cli("print-env", "env-roundtrip")
        if result.returncode == 0 and result.stdout == expected:
            break
        assert attach.poll() is None, "attach exited before forwarding its environment"
        assert time.monotonic() < deadline, (result.returncode, result.stdout, result.stderr)
        time.sleep(0.05)

    assert print_env("env-roundtrip", "ZMXTEST_VALUE") == (value + "\n").encode()
    assert print_env("env-roundtrip", "ZMXTEST_EMPTY") == b"\n"
    assert cli("print-env", "env-roundtrip", "ZMXTEST_UNSET").returncode == 1

    shell_commands = print_env("-s", "env-roundtrip")
    # Evaluate the real output with hostile-looking *values*, in an empty home.
    # Byte-exact output and absence of the file prove that syntax stayed literal.
    shell_check = (
        b"ZMXTEST_UNSET=old\n" + shell_commands
        + b"printf '%s\\000%s\\000%s' \"$ZMXTEST_VALUE\" \"${ZMXTEST_EMPTY+x}\" \"${ZMXTEST_UNSET+x}\"\n"
    )
    result = subprocess.run(
        ["/bin/sh"], input=shell_check, cwd=root,
        env={"HOME": str(home), "PATH": os.defpath}, capture_output=True, timeout=3,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == value.encode() + b"\x00x\x00", result.stdout
    assert not (root / "injected").exists()

    # A malformed EnvSet must disconnect only that peer, with no ACK. The
    # existing terminal leader and its saved environment must remain available.
    for payload in (b"X;touch injected;#=value\n", b"GOOD=value\n-X;touch injected;#\n", b"BAD_RECORD\n", b"X=a\x00b\n"):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(3)
            peer.connect(os.path.join(socket_dir, "env-roundtrip"))
            # Native ipc.Header: u8 tag, packed u32 length, trailing padding.
            peer.sendall(struct.pack("<BIxxx", 20, len(payload)) + payload)
            assert peer.recv(1) == b"", "invalid environment was acknowledged"
        assert print_env("env-roundtrip") == expected

    logs = b"".join(p.read_bytes() for p in (Path(socket_dir) / "logs").glob("*.log"))
    assert b"rejecting invalid client environment" in logs
    assert b"env-private-canary" not in logs
    assert b"touch injected" not in logs
finally:
    # Tear down the exact session and the attach process this fixture owns.
    result = cli("kill", "--force", "env-roundtrip")
    try:
        attach.wait(timeout=3)
    except subprocess.TimeoutExpired:
        # A lingering attach client is outside this change's scope; guarantee the
        # owned process is gone rather than leaking it into the test run.
        attach.kill()
        attach.wait(timeout=3)
    finally:
        os.close(master)
    assert result.returncode == 0, result.stderr
    result = cli("list", "--short")
    assert result.returncode == 0, result.stderr
    assert b"env-roundtrip" not in result.stdout.splitlines(), "test session survived cleanup"
