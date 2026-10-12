#!/usr/bin/env python3
"""macOS integration check: app-owned helpers stop when their parent exits.

Usage: DIGUP_MODELS=/path/to/models python3 scripts/test-helper-lifetime.py /path/to/digup
Uses synthetic files and a temporary index only. The worker case needs installed models.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def alive(pid):
    state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
    return bool(state) and "Z" not in state and "E" not in state  # macOS E: kernel exit in progress


def parent():
    command = json.loads(sys.argv[2])
    helper = subprocess.Popen(command + ["--parent-pid", str(os.getpid())],
                              stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(helper.pid, flush=True)
    time.sleep(60)


def check(helper):
    failures = []
    with tempfile.TemporaryDirectory(prefix="digup-lifetime-") as temporary:
        root = Path(temporary) / "files"
        root.mkdir()
        for i in range(30000):
            (root / f"note-{i}.txt").write_text("Synthetic helper lifetime test.")
        for name, args in [("estimate", ["estimate", str(root), "--json"]),
                           ("index-service", ["index-service", str(root), "--index", temporary + "/index", "--linger", "60"]),
                           ("worker", ["worker", "--text-only"])]:
            owner = subprocess.Popen([sys.executable, __file__, "--parent", json.dumps([helper] + args)],
                                     stdout=subprocess.PIPE, text=True)
            child = int(owner.stdout.readline())
            try:
                time.sleep(0.15)  # cover parent exit during startup/work, before normal completion
                if not alive(child):
                    raise RuntimeError(f"{name}: helper exited before parent (models missing?)")
                owner.kill()
                owner.wait()
                start = time.monotonic()
                while alive(child) and time.monotonic() - start < 0.5:
                    time.sleep(0.02)
                elapsed = time.monotonic() - start
                if alive(child):
                    failures.append(name)
                    print(f"FAIL {name}: survived parent for >0.5 s")
                else:
                    print(f"PASS {name}: stopped within {elapsed:.3f} s")
                    # GPU teardown can leave a macOS E process briefly after _exit. It must disappear too.
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        state = subprocess.run(["ps", "-p", str(child), "-o", "stat="],
                                               capture_output=True, text=True).stdout.strip()
                        if not state or "Z" in state:
                            break
                        time.sleep(0.02)
                    else:
                        failures.append(name)
                        print(f"FAIL {name}: kernel exit did not finish within 3 s")
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait()
                if alive(child):
                    os.kill(child, signal.SIGTERM)
    return bool(failures)


if __name__ == "__main__":
    if sys.argv[1] == "--parent":
        parent()
    else:
        sys.exit(check(str(Path(sys.argv[1]).resolve())))
