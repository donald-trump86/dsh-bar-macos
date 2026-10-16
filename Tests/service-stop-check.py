#!/usr/bin/env python3
"""Exercise the extracted managed-stop script without touching real services.

All process observations, signals, sleeps, clock reads and PID-file removals
are shell-function mocks. Only temporary fixture files are read; even a
successful stop records removal rather than deleting its fixture PID file.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "Sources/ServiceManager.swift").read_text()
MATCH = re.search(r'^    private static let stopScript = """\n(.*?)\n    """',
                  SOURCE, re.MULTILINE | re.DOTALL)
assert MATCH, "Missing production managed-stop script"
SCRIPT = textwrap.dedent(MATCH.group(1))
assert "\\" not in SCRIPT, "Update extraction for Swift string escapes before running"

# No mock delegates to a system command. In particular, kill and rm only
# journal requests, and simulated process liveness lives in this shell.
MOCKS = r'''
alive="$FIXTURE_ALIVE"
kill() {
  printf 'kill %s\n' "$*" >> "$FIXTURE_JOURNAL"
  case "$*" in
    "-0 $FIXTURE_PID") [ "$alive" = 1 ] ;;
    "$FIXTURE_PID")
      [ "$FIXTURE_KEEP_ALIVE" = 1 ] || alive=0 ;;
    "-9 $FIXTURE_PID") alive=0 ;;
    *) printf 'unexpected kill arguments\n' >&2; return 90 ;;
  esac
}
ps() {
  [ "$*" = "-p $FIXTURE_PID -o etime=" ] || return 91
  printf '%s\n' "$FIXTURE_ETIME"
}
lsof() {
  [ "$*" = "-ti :$FIXTURE_PORT -sTCP:LISTEN" ] || return 92
  printf '%s\n' "$FIXTURE_LISTENERS"
}
date() {
  [ "$*" = '+%s' ] || return 93
  printf '%s\n' "$FIXTURE_NOW"
}
sleep() {
  printf 'sleep %s\n' "$*" >> "$FIXTURE_JOURNAL"
}
rm() {
  [ "$#" = 2 ] && [ "$1" = '-f' ] && [ "$2" = "$FIXTURE_PIDFILE" ] || return 94
  printf 'remove-pidfile\n' >> "$FIXTURE_JOURNAL"
}
'''


class ManagedStopChecks(unittest.TestCase):
    def run_stop(self, elapsed, expected_seconds=8, *, listeners="424242",
                 alive=True, missing_start=False, missing_pidfile=False,
                 keep_alive=False):
        with tempfile.TemporaryDirectory(prefix="dshbar-stop-") as directory:
            root = Path(directory)
            pidfile = root / "service.pid"
            journal = root / "calls"
            journal.write_text("")
            if not missing_pidfile:
                pidfile.write_text("424242\n")
            env = dict(os.environ,
                       HOME=str(root), BASH_ENV="/dev/null", ENV="/dev/null",
                       FIXTURE_PID="424242", FIXTURE_PORT="3080",
                       FIXTURE_PIDFILE=str(pidfile), FIXTURE_JOURNAL=str(journal),
                       FIXTURE_ETIME=elapsed, FIXTURE_LISTENERS=listeners,
                       FIXTURE_NOW="2000000000", FIXTURE_ALIVE=str(int(alive)),
                       FIXTURE_KEEP_ALIVE=str(int(keep_alive)))
            start = "" if missing_start else str(2000000000 - expected_seconds)
            result = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-s", "--",
                 str(pidfile), "3080", start], input=MOCKS + "\n" + SCRIPT,
                text=True, capture_output=True, env=env, cwd=root, timeout=5)
            calls = journal.read_text().splitlines()
            # Removal must always be simulated, including on successful stops.
            self.assertEqual(pidfile.exists(), not missing_pidfile,
                             "Stop script changed the actual fixture PID file")
            self.assertTrue(all(call in ("kill -0 424242", "kill 424242",
                                         "kill -9 424242", "remove-pidfile",
                                         "sleep 0.15", "sleep 0.3")
                                for call in calls), calls)
            return result, calls

    def assert_stopped(self, elapsed, seconds, **kwargs):
        result, calls = self.run_stop(elapsed, seconds, **kwargs)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "STOPPED"),
                         f"{elapsed!r}: stderr={result.stderr!r}, calls={calls}")
        self.assertEqual(result.stderr, "")
        signals = [call for call in calls if call.startswith("kill ")
                   and not call.startswith("kill -0 ")]
        self.assertEqual(signals, ["kill 424242"] +
                         (["kill -9 424242"] if kwargs.get("keep_alive") else []))
        self.assertEqual(calls.count("remove-pidfile"), 1)
        return calls

    def assert_refused(self, elapsed, **kwargs):
        result, calls = self.run_stop(elapsed, **kwargs)
        self.assertEqual((result.returncode, result.stdout.strip()), (6, "UNVERIFIED-PID"),
                         f"{elapsed!r}: stderr={result.stderr!r}, calls={calls}")
        self.assertEqual(result.stderr, "", f"{elapsed!r}: parser emitted an error")
        self.assertFalse(any(call.startswith("kill ") and
                             not call.startswith("kill -0 ") for call in calls), calls)
        self.assertNotIn("remove-pidfile", calls)

    def test_decimal_elapsed_formats(self):
        cases = (
            ("00:00", 0), ("00:01", 1), ("01:02", 62), ("12:34", 754),
            ("1:2", 62), ("01:02:03", 3723), ("00:00:00", 0),
            ("0-00:00:00", 0), ("1-02:03:04", 93784),
            ("00:08", 8), ("00:09", 9), ("08:00", 480), ("09:00", 540),
            ("08:00:00", 28800), ("09:00:00", 32400),
            ("01:08:09", 4089), ("8-08:09:08", 720548),
            ("08-00:00:08", 691208), ("09-00:00:08", 777608),
        )
        for elapsed, seconds in cases:
            with self.subTest(elapsed=elapsed):
                self.assert_stopped(elapsed, seconds)

    def test_malformed_elapsed_fails_closed(self):
        for elapsed in ("", "garbage", "08", ":08", "00:", "00::08", "00:08:",
                        "00:00:08:", "00:00:00:08", "x:08", "00:x", "x:00:08",
                        "00:x:08", "00:00:x", "x-00:00:08", "-00:00:08",
                        "1-00:08", "1-", "1--00:00:08", "1-00:00:08-0",
                        "+00:08", "00:-08", "00:0+8", "00:0*8", "00:08\n00:08"):
            with self.subTest(elapsed=elapsed):
                self.assert_refused(elapsed)

    def test_missing_fingerprint_preserves_identity(self):
        self.assert_refused("00:08", missing_start=True)

    def test_pid_reuse_preserves_identity(self):
        self.assert_refused("01:00", expected_seconds=8)
        self.assert_refused("00:08", expected_seconds=60)

    def test_start_drift_boundary(self):
        for expected in (30, 90):
            with self.subTest(expected=expected):
                result, calls = self.run_stop("01:00", expected)
                self.assertEqual((result.returncode, result.stdout.strip()), (0, "STOPPED"))
                self.assertIn("kill 424242", calls)
        for expected in (29, 91):
            with self.subTest(expected=expected):
                self.assert_refused("01:00", expected_seconds=expected)

    def test_foreign_listener_retains_stale_pid_cleanup(self):
        result, calls = self.run_stop("00:08", listeners="999999")
        self.assertEqual((result.returncode, result.stdout.strip()), (5, "FOREIGN-LISTENER"))
        self.assertEqual(calls, ["kill -0 424242", "remove-pidfile"])

    def test_dead_pid_and_missing_pidfile_do_not_signal_listener(self):
        for options in ({"alive": False}, {"missing_pidfile": True}):
            with self.subTest(options=options):
                result, calls = self.run_stop("00:08", listeners="999999", **options)
                self.assertEqual((result.returncode, result.stdout.strip()),
                                 (5, "FOREIGN-LISTENER"))
                self.assertFalse(any(call.startswith("kill ") and
                                     not call.startswith("kill -0 ") for call in calls))
                self.assertIn("remove-pidfile", calls)

    def test_no_listener_retains_stale_pid_cleanup(self):
        result, calls = self.run_stop("00:08", listeners="")
        self.assertEqual((result.returncode, result.stdout.strip()), (4, "NONE"))
        self.assertEqual(calls, ["kill -0 424242", "remove-pidfile"])

    def test_force_kill_only_targets_verified_pid(self):
        calls = self.assert_stopped("01:02", 62, keep_alive=True)
        self.assertEqual(calls.count("sleep 0.15"), 20)
        self.assertEqual(calls.count("sleep 0.3"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
