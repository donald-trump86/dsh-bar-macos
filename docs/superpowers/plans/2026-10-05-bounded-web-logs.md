# Bounded Web Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep DSH Bar-managed Web logs within 30 MiB even after Bar quits, safely remove the legacy log, and publish 0.1.5.

**Architecture:** A private mode of the existing signed executable owns a stdin pipe and synchronously rotates bounded raw-byte log files. ServiceManager still launches the actual Web Process and validates its real PID. A separate bounded control pipe supplies readiness and a launch-specific URL; LogWindow follows file identity rather than size alone.

**Tech Stack:** Swift, Foundation, Darwin; macOS 13.0+, existing shell checks and GitHub Actions; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-05-bounded-web-logs-design.md`

## Global Constraints

- Each log file is limited to `10 * 1024 * 1024` bytes; current plus exactly two archive slots have a total limit of 30 MiB.
- Directory permissions 0700; logs/lock permissions 0600; persistent lock file is never removed during rotation.
- Normal Quit retains Web and logger; logger drains to EOF on stop. Keep actual Web PID, ownership checks and no-auto-browser behavior.
- Fixed-size byte buffers, partial-write/EINTR handling, finite readiness/lock waits; failures after readiness drain/discard output rather than growing files or blocking Web.
- Only launch-specific control messages may populate the in-memory authenticated URL; no credential sidecar or history mining.
- Do not unlink/truncate the legacy log until verified legacy writers have closed it. Current Web carries this session, so migration must not silently interrupt ongoing execution.
- 0.1.4 → 0.1.5 in both plist version fields; existing universal Release workflow publishes v0.1.5 as pre-release.

## Review Focus

- Multiple Bar instances/restarts share a global log pathname: the second logger must fail finitely without moving files while the first owns them (Task 1).
- Producer emits one huge line: memory and disk must remain bounded, and retained byte suffix must be exact (Task 1).
- Bar quits or control pipe closes early: logger must survive and keep draining/rotating until actual stdout EOF (Task 1).
- PID persistence fails after Web spawn: no untracked service or retained pipe writer must survive (Task 2).
- New current inode regrows beyond old read offset between refreshes: window must reset its offset even without a size decrease (Task 3).

---

### Task 1: Detached bounded byte writer and real executable checks

**Files:**
- Create: `Sources/RotatingLogWriter.swift`
- Create: `Tests/log-rotation-check.sh`, `Tests/LogRotationChecks.swift`, `Tests/log-rotation-process-check.py`
- Modify: `Sources/main.swift:5-9`, `build.sh:37-50`, `Tests/run-checks.sh:136`

**Interfaces:**
- Produces: `enum RotatingLogWriter` with `static let maximumFileBytes: Int = 10 * 1024 * 1024`, `static func run(logURL: URL, port: Int) -> Int32`, and `static func authenticatedURL(in text: String, port: Int) -> URL?`.
- Produces: `final class LogWriterProcess` with `static func start(logURL: URL, port: Int) throws -> LogWriterProcess`, `let outputHandle: FileHandle`, `var authenticatedURL: URL? { get }`, `func closeParentPipeHandles()`.
- Internal helper CLI: `--internal-log-writer <absolute-log-path> <port>`. Validate argument count, absolute path, and port 1...65535 before any GUI initialization.

- [ ] **Step 1: Write executable failing checks.** Compile the actual production Swift writer with a small @main test entry. Python process checks invoke that binary in a unique temp directory; no frameworks. Assert the production limit is 10485760; write 35 MiB of distinguishable raw chunks including no-newline data; assert each of three files ≤10485760 and `.2 + .1 + current` equals the same-length input suffix. Assert exact-limit input does not prematurely rotate, empty input exits, files are 0600 and directory 0700. Check finite lock contention, EOF lock release, old oversized offline file bounded-tail migration, closed control pipe survival, detached parent exit followed by further producer data, and failed sink still draining. Swift checks assert only requested loopback host/port URLs are accepted and split startup chunks/rotation do not lose URL capture.
- [ ] **Step 2: Run `bash Tests/log-rotation-check.sh`.** Expected FAIL because `Sources/RotatingLogWriter.swift` does not exist.
- [ ] **Step 3: Implement writer and launcher interfaces.** Use exclusive CLOEXEC lock with ≤5s wait, fixed 64 KiB read buffer, single-owner split writes/rename rotation, startup capture bounded to 128 KiB, control lines `READY\n` and `URL <validated-url>\n`. Ignore SIGHUP/SIGPIPE and detach the logger session; readiness must be emitted only after acquiring lock/opening the bounded fresh log. Parent control reader stores URL under a lock and signals a semaphore with ≤6s wait. Runtime sink errors emit one diagnostic control message then drain/discard; startup errors exit nonzero without READY. Release parent output endpoints on every path; helper sees EOF without a retained write end. Never terminate a healthy logger on normal Bar cleanup.
- [ ] **Step 4: Wire CLI before NSApplication, add Swift source to explicit build source list, and invoke new check from `Tests/run-checks.sh`.** Run `bash Tests/log-rotation-check.sh`; expected PASS for all byte, process and error checks.
- [ ] **Step 5: Commit.** `git add Sources/RotatingLogWriter.swift Sources/main.swift build.sh Tests/LogRotationChecks.swift Tests/log-rotation-check.sh Tests/log-rotation-process-check.py Tests/run-checks.sh && git commit -m 'feat: add detached bounded web log writer'`.

### Task 2: Managed launch integration and launch-specific authentication

**Files:**
- Modify: `Sources/ServiceManager.swift:65-67,1067-1070,1170-1185,1273-1300,1372-1375,1643-1694`
- Modify: `Tests/log-rotation-check.sh`, `Tests/LogRotationChecks.swift` (integration assertions)

**Interfaces:**
- Consumes: Task 1 `LogWriterProcess.start(logURL:port:)`, `outputHandle`, `authenticatedURL`, `closeParentPipeHandles()`.
- Produces: `private func launchProcess(path: String, port: Int) throws -> (Process, LogWriterProcess)`; stored property `private var launchedLogWriter: LogWriterProcess?` replaces the direct log FileHandle.

- [ ] **Step 1: Add failing integration assertions.** Check real launch source uses logger readiness before `process.run()`, uses the same writer handle for stdout/stderr, closes parent endpoints via defer on success/failure, and terminates the just-spawned Web if post-spawn persistence fails. Reject any remaining direct `seekToEndOfFile()` launch or authenticated URL extraction from old log offsets. Add runtime URL control checks with logs rotating before parent retrieval.
- [ ] **Step 2: Run `bash Tests/log-rotation-check.sh`.** Expected FAIL for old ServiceManager direct-file launch.
- [ ] **Step 3: Update launch callers and cleanup.** Start logger first and Web second, preserve Web Process/PID, defer parent-end closure, return Process+logger. Read launch-specific URL after existing readiness probes; clear stored capture when service stops without killing logger. Remove obsolete file-offset auth scan. Post-spawn thrown errors terminate only the newly spawned Process and close parent endpoints. Preserve service ownership, probes, restart budgets and normal Quit behavior.
- [ ] **Step 4: Run `make check` and an arm64 build (`ARCHS=arm64 ./build.sh`).** Expected all checks PASS and signed app builds; verify no new auth-history scan or Bar-owned output reader remains.
- [ ] **Step 5: Commit.** `git add Sources/ServiceManager.swift Tests/log-rotation-check.sh Tests/LogRotationChecks.swift && git commit -m 'fix: route managed web launches through rotating logs'`.

### Task 3: Rotation-aware live log offsets

**Files:**
- Modify: `Sources/LogWindow.swift:200-258`
- Modify: `Sources/RotatingLogWriter.swift` (small shared read-position helper)
- Modify: `Tests/LogRotationChecks.swift`

**Interfaces:**
- Produces: `struct LogFileIdentity: Equatable` with `let device: UInt64`, `let inode: UInt64` and `static func read(from handle: FileHandle) throws -> (LogFileIdentity, UInt64)`.
- Produces: `static func readOffset(size: UInt64, offset: UInt64, previous: LogFileIdentity?, current: LogFileIdentity) -> UInt64`; tail cap is existing `512 * 1024` bytes.

- [ ] **Step 1: Add failing Swift assertions.** New inode with size≥old offset must reset to zero/tail; same inode normal append preserves offset; same inode shrinking resets; initial large file tails only 512 KiB. Test actual opened file identity across rename/recreate, not just fabricated values.
- [ ] **Step 2: Run `bash Tests/log-rotation-check.sh`.** Expected FAIL because identity helper is absent.
- [ ] **Step 3: Implement `fstat` identity/size and offset helper, use them after opening the reader in LogWindow.** Save/reset identity with read state, preserve generation guard against Clear, pause/search/memory cap/token redaction. Close reader on all paths.
- [ ] **Step 4: Run `make check` and `./build.sh`.** Expected PASS, universal arm64+x86_64 output, strict signature verification.
- [ ] **Step 5: Commit.** `git add Sources/LogWindow.swift Sources/RotatingLogWriter.swift Tests/LogRotationChecks.swift && git commit -m 'fix: follow new log inode after rotation'`.

### Task 4: Version, verification, release and safe legacy cleanup

**Files:**
- Modify: `Info.plist:19-22`, `README.md:73,129-130,168-172`
- Update task checkboxes in this plan as tasks complete.

**Interfaces:**
- Consumes: Task 1–3 production logger, launch and window checks; existing `build.sh` and `.github/workflows/release.yml`.
- Produces: GitHub v0.1.5 pre-release with universal ZIP and checksum; honest recorded outcome for legacy-log cleanup.

- [ ] **Step 1: Set both source plist version fields and README examples to 0.1.5; document 10 MiB current + two archives, independent of Bar lifecycle, and the new source file.** Verify `plutil -lint Info.plist` and `git diff --check`.
- [ ] **Step 2: Run `make check && ./build.sh`.** Verify `lipo 'build/DeepSeek Harness Bar.app/Contents/MacOS/dsh-bar' -verify_arch arm64 x86_64`, both bundle versions equal 0.1.5, minimum OS13.0 and `codesign --verify --deep --strict` PASS. Run fresh whole-branch review; fix any findings with a corresponding check before publishing.
- [ ] **Step 3: Commit release changes; create annotated v0.1.5; non-force atomic push main and tag.** Verify remote tag peels to released commit. Tag must not already exist; do not overwrite remote changes.
- [ ] **Step 4: Track Release workflow with a managed background `gh run watch <run-id> --exit-status`, collect completion, inspect v0.1.5 Release JSON and ZIP/checksum assets.** Update release notes to describe rotation while preserving workflow installation/signing warnings. Verify downloaded checksum against ZIP. CI/release failures are investigated before retry, never reported as released prematurely.
- [ ] **Step 5: Prepare safe cleanup only after release/testing.** Reconfirm `/Users/jasondai/.dsh/logs/dsh-web.log` absolute resolved path and live writers; request required sandbox permission. Since this Web carries the current session, present a short safety handoff if its restart is required. A deferred migration must validate exact PIDs/commands/start times, stop old Bar/Web without touching unrelated listeners, verify all old-inode writers gone, then delete only the authorized old log. Do not claim completion based on scheduling alone; collect task result or await user-confirmed safe restart before final cleanup verification. Installing the new app locally is a separate explicit choice, not silently bundled into GitHub release.
- [ ] **Step 6: Record final outcomes and commit plan checkbox updates before the final publication commit/tag where possible; final reply links release and reports actual cleanup status.** No uncollected background jobs or speculative success claims.
