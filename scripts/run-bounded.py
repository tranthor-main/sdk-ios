#!/usr/bin/env python3
"""Bound a build/test and stop owned descendants, including orphaned xctest processes."""
import os
import signal
import subprocess
import sys
import time


def snapshot():
    # One snapshot avoids spawning one pgrep process for every compiler/test descendant.
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,lstart="], capture_output=True, text=True, check=True
    ).stdout
    rows = {}
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) == 3:
            rows[int(fields[0])] = (int(fields[1]), fields[2])
    return rows


def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


seconds = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)
started = time.monotonic()
owned = {}

def interrupted(signum, _frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)


def collect(rows):
    descendants = {process.pid}
    while True:
        found = {pid for pid, (parent, _) in rows.items() if parent in descendants}
        new = found - descendants
        if not new:
            break
        descendants.update(new)
    for pid in descendants - {process.pid}:
        owned[pid] = rows[pid][1]


def signal_owned(sig):
    rows = snapshot()
    collect(rows)
    for pid, birth in owned.items():
        # PID reuse must never let cleanup kill somebody else's process on the shared Mac.
        if pid in rows and rows[pid][1] == birth:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass


try:
    while process.poll() is None:
        collect(snapshot())
        if time.monotonic() - started > seconds:
            print("TIMEOUT", seconds, command, flush=True)
            signal_group(process.pid, signal.SIGTERM)
            signal_owned(signal.SIGTERM)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                signal_group(process.pid, signal.SIGKILL)
                process.wait()
            sys.exit(124)
        time.sleep(0.2)
    sys.exit(process.returncode)
finally:
    signal_owned(signal.SIGTERM)
    signal_group(process.pid, signal.SIGTERM)
    time.sleep(0.1)
    signal_owned(signal.SIGKILL)
    signal_group(process.pid, signal.SIGKILL)
    print(f"WALL_SECONDS={time.monotonic() - started:.2f}", flush=True)
