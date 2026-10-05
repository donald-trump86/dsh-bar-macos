#!/usr/bin/env python3
"""Real pipe/process tests; every timeout fails rather than leaving workers."""
import fcntl
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import tempfile
import time

BINARY = str(Path(sys.argv[1]).resolve())
LIMIT = 10 * 1024 * 1024


def start(path, port=3080):
    p = subprocess.Popen([BINARY, "--internal-log-writer", str(path), str(port)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    ready, _, _ = select.select([p.stdout], [], [], 8)
    assert ready, "readiness timed out"
    assert p.stdout.readline() == b"READY\n", p.stderr.read()
    return p


def finish(p):
    p.stdin.close()
    assert p.wait(timeout=10) == 0, p.stderr.read()
    control = p.stdout.read()
    p.stdout.close()
    p.stderr.close()
    return control


def retained(path):
    files = [Path(str(path) + ".2"), Path(str(path) + ".1"), path]
    for file in files:
        if file.exists():
            assert file.stat().st_size <= LIMIT, (file, file.stat().st_size)
            assert stat.S_IMODE(file.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    return b"".join(file.read_bytes() for file in files if file.exists())


with tempfile.TemporaryDirectory(prefix="dsh-rotation-process-") as root:
    root = Path(root).resolve()
    path = root / "large" / "dsh-web.log"
    p = start(path)
    stream = b"".join(bytes([i]) * (1024 * 1024) for i in range(35)) + b"end"
    # No newline in the huge write: do not allocate/buffer an unbounded line.
    p.stdin.write(stream)
    finish(p)
    actual = retained(path)
    assert actual == stream[-len(actual):] and 20 * 1024 * 1024 <= len(actual) <= 30 * 1024 * 1024
    assert len(list(path.parent.glob("dsh-web.log*"))) == 4  # three logs and persistent lock
    print("PASS 35 MiB no-newline exact retained suffix, limits and permissions")

    path = root / "exact" / "dsh-web.log"
    p = start(path)
    p.stdin.write(b"x" * LIMIT)
    finish(p)
    assert path.stat().st_size == LIMIT and not Path(str(path) + ".1").exists()
    # EOF releases ownership and the next launch archives nonempty output.
    p = start(path)
    finish(p)
    assert path.stat().st_size == 0 and Path(str(path) + ".1").stat().st_size == LIMIT
    print("PASS exact threshold, empty input, EOF release and sequential launch")

    path = root / "auth" / "dsh-web.log"
    p = start(path)
    p.stdin.write(b"http://localhost:3081/?token=wrong\nhttp://127.0.0.1:3080/?tok")
    p.stdin.flush()
    p.stdin.write(b"en=current\n" + b"z" * (35 * 1024 * 1024))
    control = finish(p)
    assert control == b"URL http://127.0.0.1:3080/?token=current\n", control
    assert b"current" not in retained(path)
    print("PASS split URL captured on control pipe despite subsequent rotation")

    path = root / "lock" / "dsh-web.log"
    first = start(path)
    before = path.stat().st_ino
    began = time.monotonic()
    second = subprocess.run([BINARY, "--internal-log-writer", str(path), "3080"],
                            input=b"", capture_output=True, timeout=8)
    assert second.returncode != 0 and b"READY" not in second.stdout
    assert time.monotonic() - began < 8 and path.stat().st_ino == before
    finish(first)
    print("PASS lock contention fails finitely without touching another owner's file")

    path = root / "offline" / "dsh-web.log"
    path.parent.mkdir()
    legacy = b"head" + b"l" * (LIMIT + 50) + b"tail"
    path.write_bytes(legacy)
    Path(str(path) + ".1").write_bytes(b"older" + b"o" * (LIMIT + 50))
    Path(str(path) + ".2").write_bytes(b"oldest" + b"a" * (LIMIT + 50))
    p = start(path)
    finish(p)
    assert Path(str(path) + ".1").read_bytes() == legacy[-LIMIT:]
    retained(path)
    print("PASS offline oversized legacy current and archives bounded")

    path = root / "legacy-holders" / "dsh-web.log"
    path.parent.mkdir()
    path.write_bytes(b"legacy-still-open")
    original_inode = path.stat().st_ino
    for mode in (os.O_WRONLY, os.O_RDWR):
        holder = os.open(path, mode)
        try:
            began = time.monotonic()
            refused = subprocess.run([BINARY, "--internal-log-writer", str(path), "3080"],
                                     input=b"", capture_output=True, timeout=8)
            assert refused.returncode != 0 and b"READY" not in refused.stdout
            assert time.monotonic() - began < 8
            assert path.stat().st_ino == original_inode and path.read_bytes() == b"legacy-still-open"
        finally:
            os.close(holder)
    holder = os.open(path, os.O_RDONLY)
    try:
        p = start(path)
        finish(p)
        assert os.read(holder, 100) == b"legacy-still-open"
        assert Path(str(path) + ".1").stat().st_ino == original_inode
        assert path.stat().st_ino != original_inode
    finally:
        os.close(holder)
    print("PASS real read-only holder accepted; writable and read-write legacy holders refused untouched")

    path = root / "closed-control" / "dsh-web.log"
    p = start(path)
    p.stdout.close()
    p.stdin.write(b"http://localhost:3080/?token=current\n" + b"y" * (35 * 1024 * 1024))
    p.stdin.close()
    assert p.wait(timeout=10) == 0
    p.stderr.close()
    retained(path)
    print("PASS closed control pipe cannot SIGPIPE the logger")

    path = root / "fault" / "dsh-web.log"
    p = start(path)
    # A directory in a reserved archive slot must be refused, never recursively
    # removed, and the writer must drain/discard rather than deadlock its Web.
    blocker = Path(str(path) + ".2")
    blocker.mkdir()
    marker = blocker / "do-not-delete"
    marker.write_text("unrelated")
    p.stdin.write(b"f" * (35 * 1024 * 1024))
    control = finish(p)
    assert b"ERROR" in control and marker.read_text() == "unrelated"
    assert path.stat().st_size <= LIMIT
    print("PASS runtime rotation failure drains input and preserves foreign directories")

    path = root / "detached" / "dsh-web.log"
    read_fd, write_fd = os.pipe()
    # Simulated Bar parent starts helper, reads READY, and exits. This driver's
    # producer FD stays open, mirroring Web's independent inherited stdout.
    program = """import subprocess,sys
p=subprocess.Popen([sys.argv[1],'--internal-log-writer',sys.argv[2],'3080'],stdin=int(sys.argv[3]),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
assert p.stdout.readline()==b'READY\\n'
print(p.pid,flush=True)
"""
    parent = subprocess.Popen([sys.executable, "-c", program, BINARY, str(path), str(read_fd)],
                              pass_fds=(read_fd,), stdout=subprocess.PIPE)
    os.close(read_fd)
    helper_pid = int(parent.stdout.readline())
    assert parent.wait(timeout=8) == 0
    parent.stdout.close()
    queue = select.kqueue()
    queue.control([select.kevent(helper_pid, filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD, fflags=select.KQ_NOTE_EXIT)], 0, 0)
    with os.fdopen(write_fd, "wb", buffering=0) as producer:
        data = b"after-parent-exit" * (3 * 1024 * 1024)
        view = memoryview(data)
        while view:
            n = producer.write(view)
            view = view[n:]
    assert queue.control(None, 1, 10), "detached logger did not finish at producer EOF"
    queue.close()
    actual = retained(path)
    assert actual == data[-len(actual):]
    print("PASS detached helper continues rotating after its Bar parent exits")

    path = root / "native-launcher" / "dsh-web.log"
    result = subprocess.run([BINARY, "--parent", str(path), str(1024 * 1024)],
                            capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    # Acquiring the released lifetime lock waits for the actual helper to drain.
    lock = os.open(str(path) + ".lock", os.O_RDWR)
    fcntl.flock(lock, fcntl.LOCK_EX)
    assert path.read_bytes() == b"a" * (1024 * 1024)
    os.close(lock)
    print("PASS native parent readiness and output-end closure")
