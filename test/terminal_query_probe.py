#!/usr/bin/env python3
import argparse
import os
import re
import struct
import subprocess
import sys
import textwrap
from typing import Optional


def frames_to_text(data: bytes) -> str:
    i = 0
    out = bytearray()
    while i + 5 <= len(data):
        tag = data[i]
        size = struct.unpack_from("<I", data, i + 1)[0]
        i += 5
        if i + size > len(data):
            break
        payload = data[i : i + size]
        i += size
        if tag in (1, 14, 15):
            out.extend(payload)
    return out.decode("utf-8", errors="backslashreplace")


def python_probe_code(query: Optional[str], split: bool) -> str:
    if split:
        writes = "os.write(1, b'\\x1b['); time.sleep(0.05); os.write(1, b'c')"
    else:
        assert query is not None
        query_bytes = query.encode("utf-8").decode("unicode_escape").encode("latin1")
        writes = f"os.write(1, {query_bytes!r})"
    return textwrap.dedent(
        f"""
        import os, select, sys, termios, time, tty
        fd = 0
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            {writes}
            deadline = time.time() + 2.0
            chunks = []
            while time.time() < deadline and sum(len(c) for c in chunks) < 64:
                readable, _, _ = select.select([fd], [], [], max(0, deadline - time.time()))
                if not readable:
                    break
                chunk = os.read(fd, 64)
                if not chunk:
                    break
                chunks.append(chunk)
            resp = b''.join(chunks)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        print('')
        print('RESP_HEX=' + resp.hex())
        print('DONE')
        """
    ).strip()


def extract_hex(text: str) -> str | None:
    matches = re.findall(r"RESP_HEX=([0-9a-f]*)", text)
    return matches[-1] if matches else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["run", "control"], required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--query")
    parser.add_argument("--split", action="store_true")
    parser.add_argument("--expect")
    parser.add_argument("--expect-regex")
    args = parser.parse_args()

    zmx = os.environ["ZMX"]
    env = os.environ.copy()
    env.setdefault("SHELL", "/bin/bash")
    code = python_probe_code(args.query, args.split)
    if args.mode == "control":
        cmd = [zmx, "control", "--rows", "24", "--cols", "80", args.session, "python3", "-c", code]
    else:
        cmd = [zmx, "run", args.session, "python3", "-c", code]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=8, check=False)
    text = frames_to_text(proc.stdout) if args.mode == "control" else proc.stdout.decode("utf-8", errors="backslashreplace")
    if proc.stderr:
        text += "\n[stderr]\n" + proc.stderr.decode("utf-8", errors="replace")
    got = extract_hex(text)
    print(text)
    print(f"GOT_HEX={got!r}")
    if args.expect is not None:
        return 0 if got == args.expect else 1
    if args.expect_regex is not None:
        return 0 if got is not None and re.fullmatch(args.expect_regex, got) else 1
    parser.error("one of --expect or --expect-regex is required")


if __name__ == "__main__":
    raise SystemExit(main())
