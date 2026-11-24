# WebKit frame-identity spoofing — real-WebKit reproduction (OE11044060622355)

## Why this package exists

Apple's reviewer (Nick, Product Security) closed report **OE11044060622355** with:

> The files we received are a standalone program that reimplements the WebKit classes rather than
> running in WebKit itself, so they don't show the issue in a real build. Please send a
> reproduction against a real WebKit build with Site Isolation enabled that shows a dialog
> attributed to a frame whose process did not send the message.

That critique of the original PoC is accurate — it embedded the five real function bodies
verbatim, but ran them against hand-written stand-in classes, not against compiled, linked
WebKit. This package replaces that with a real WebKit build and a real test. This environment has
no macOS/Xcode toolchain, so it's never been compiled or run here — it runs on your GitHub
Actions (macOS runner), the same way as your other WebKit finding's PoCs. **Real status as of the
tenth run (2026-11-22/23): the core-build chain reliably goes green, but every run through the
ninth has come back INCONCLUSIVE with the same two bundles (`JavaScriptCore.framework`,
`EnhancedSecurity.xpc`) discarded by our own verification step — confirmed twice now to be a false
positive from `codesign --verify` on an ad-hoc-signed binary, not real corruption. v5 (this round)
drops `codesign` entirely for a direct Mach-O validity check, and adds logic so a phase that finds
the core already complete skips its build step instead of spending hours confirming there's nothing
to do. Tested locally; not yet proven by a real run — see "v4 real run (tenth run)" below.**

## What's actually being claimed (unchanged from the original report)

`WebPageProxy::runJavaScriptAlert`, `runJavaScriptConfirm`, `runJavaScriptPrompt`, and
`runOpenPanel` (`Source/WebKit/UIProcess/WebPageProxy.cpp`) resolve a `WebFrameProxy` from an
IPC-supplied `FrameIdentifier` via a global, connection-blind registry, and check only that the
resolved frame belongs to the current page. None of them checks that the IPC message's actual
sender (the real `IPC::Connection`/process it arrived on) owns that frame. The structurally
identical sibling `runBeforeUnloadConfirmPanel` is the one correct example — it additionally
checks `&frame->frameProcess().process() != webProcess.ptr()` and bails if the sender doesn't own
the named frame.

**Re-verified against WebKit `main` at commit `86af064084e1cfd66a11252d75c14808c1196a5c`
(2026-10-31) before writing this package** — the gap is still there, byte-for-byte consistent with
the original report. Citations: the four vulnerable handlers are at roughly
`WebPageProxy.cpp:12788-12873` (alert/confirm/prompt) and `:13139+` (openPanel); the one correct
sibling is at `:13059-13093`.

## What this package adds: a real build + a real test, scoped to one call site

Rather than try to prove all four handlers at once in a single multi-hour CI run, this follows the
same "start with one call site, prove the architecture works, then extend" discipline already
used successfully elsewhere in this engagement. It targets **`runJavaScriptAlert`** only, via Site
Isolation (so the alert really is raised by a different process than the one that owns the main
frame) plus one small, disclosed instrumentation patch.

### Why a patch is needed at all (and what it does / doesn't do)

There is no legitimate public API that lets a cross-origin iframe's JavaScript make its own
`alert()` claim to be a different frame — `WebChromeClient::runJavaScriptAlert`
(`Source/WebKit/WebProcess/WebCoreSupport/WebChromeClient.cpp:627-648`) always sends the frame's
own real `frameID()`/`info()`. Demonstrating the spoof therefore requires a stand-in for "the
cross-origin iframe's WebContent process has been compromised and sends this exact real IPC
message with a forged `frameID`" — which is what a genuine renderer memory-corruption exploit
would let a real attacker do. That's `patches/0001-sender-instrumentation-alert-frame-spoof.patch`:

- Gated entirely behind `#if ENABLE(IPC_TESTING_API)` (on by default for any Debug/ASan Cocoa
  build, confirmed at `Source/WTF/wtf/PlatformEnable.h:327-332` — no special build flags needed,
  and compiled out of any non-debug/shipping build).
- Only fires when the alert text starts with the literal marker `POC_FRAME_SPOOF:` — ordinary
  `alert()` calls are completely unaffected.
- When it fires, it substitutes `frame.mainFrame().frameID()` for `webFrame->frameID()` as the
  `FrameIdentifier` argument of the real `Messages::WebPageProxy::RunJavaScriptAlert` IPC message.
  `frame.mainFrame()` works whether the main frame is Local or Remote to this process
  (`WebCore::Frame::mainFrame()`/`::frameID()`, `Source/WebCore/page/Frame.h:88-94`, inherited
  unmodified by `RemoteFrame`); the identical accessor chain is already used in shipping code at
  `Source/WebKit/WebProcess/WebCoreSupport/WebSpeechRecognitionConnection.cpp:89`.
- **`frameInfo` (`webFrame->info()`) is deliberately left completely untouched** — only `frameID`
  is substituted. This isolates exactly this report's claimed bug (the receiving handler trusts
  `frameID` without checking who sent it) from any separate question of whether `frameInfo`'s own
  *contents* can be forged (a different, already-submitted finding from this same engagement).
- Everything downstream of the send — `WebPageProxy::runJavaScriptAlert`,
  `API::FrameInfo::create`/`stateSnapshot`, `WKFrameInfo` — is completely stock, unmodified WebKit.

### The test: `patches/0002-test-addition-frame-spoof.patch`

Adds `TEST(SiteIsolation, FrameIdentitySpoofingPoC_AlertAttributedToFrameWhoseProcessDidNotSendMessage)`
to `Tools/TestWebKitAPI/Tests/WebKit/WKWebView/SiteIsolation.mm`, modeled directly on that file's
own existing `IframeWithConfirm`/`IframeWithPrompt`/`MainFrameHeartbeatContinuesWhileCrossSiteIframeDialogShown`
tests (same `siteIsolatedViewAndDelegate(server)` helper, same `TestUIDelegate` pattern, same
`mainFrame.info._processIdentifier` idiom already used elsewhere in that file to confirm two real,
separate WebContent processes).

It loads `https://example.com/example` (main frame) with a cross-origin
`<iframe src='https://webkit.org/webkit'>`, which calls
`alert('POC_FRAME_SPOOF:forged alert')`. It then asserts, on the `WKFrameInfo` the app's
`WKUIDelegate` actually receives:

- `securityOrigin.host == "webkit.org"` — correct, because `frameInfo` was never touched. The
  dialog honestly still says it came from the real sender.
- `isMainFrame == true` and `_processIdentifier == <the main frame's real pid>` — **wrong**. These
  two fields are derived not from `frameInfo` but by `API::FrameInfo::stateSnapshot`
  (`Source/WebKit/UIProcess/API/APIFrameInfo.cpp:42-53`) **re-resolving the (forged) `frameID`**
  through `WebFrameProxy`'s global registry — i.e. exactly the trust gap this report describes,
  not anything the real sender legitimately controls.

So a successful run shows, with real compiled code: an alert honestly labeled as coming from
`webkit.org`'s own process, yet reported to the app as `isMainFrame = YES` with the *main frame's*
process identifier — a dialog attributed to a frame whose process did not send the message,
exactly as requested.

### Precedent this leans on

`Tools/TestWebKitAPI/Tests/WebKit/WKWebView/SiteIsolation.mm` already contains dozens of passing
tests exercising this exact Site Isolation / cross-process-frame infrastructure, including dialogs
specifically (`IframeWithAlert`-style tests, `MainFrameHeartbeatContinuesWhileCrossSiteIframeDialogShown`,
`SimultaneousDialogsFromMultipleCrossOriginFrames`) — so the only genuinely new code here is the
one-field patch and the one new test; the Site Isolation setup, multi-process confirmation, and
dialog-delegate plumbing are all WebKit's own, already-proven test machinery, not anything built
from scratch for this PoC.

## v2 (2026-11-01): the first version's single job couldn't fit build + TestWebKitAPI in ~6 hours

The first version of this package used one job running `Tools/Scripts/build-webkit --debug`
(no scope flag) followed by `run-api-tests --no-build`. That command builds Xcode's **"Everything
up to WebKit + Tools"** scheme — which does include `TestWebKitAPI`, but also drags in
MiniBrowser, MobileMiniBrowser, SwiftBrowser, and `gtest.framework`, none of which this PoC needs.
**The real run: the build step alone ran 5h49m, and the whole job was then cut off by GitHub's
own ~6-hour hard per-job cap before `TestWebKitAPI` was actually produced** — `run-api-tests`
failed immediately with `TestWebKitAPI was not found at .../WebKitBuild/Debug/TestWebKitAPI`.

**v2 splits the work across two jobs, along WebKit's own real Xcode scheme boundary** (confirmed
by reading `WebKit.xcworkspace`'s scheme files directly, not guessed):

- **Job `build-core`**: `Tools/Scripts/build-webkit --debug --only="Everything up to WebKit"` —
  this named scheme builds WTF, JavaScriptCore, ANGLE, WebGPU, WebInspectorUI, WebKitLegacy, and
  the core WebKit framework, including all code generation — and **excludes** TestWebKitAPI and
  the other tools entirely (confirmed: zero references to TestWebKitAPI in this scheme's `.xcscheme`
  file). It runs to its own natural completion — no artificial time-based kill — then the whole
  `WebKitBuild/Debug` product directory is tarred and uploaded as an artifact.
- **Job `build-tests-and-run`** (`needs: build-core`): re-fetches the identical pinned commit,
  re-applies the identical two patches, downloads and restores job 1's checkpoint into
  `WebKitBuild/Debug`, then runs `Tools/Scripts/build-api-tests --debug` — which builds only the
  much narrower `TestWebKitAPI` Xcode *project* scheme (confirmed via `Tools/Scripts/build-api-tests`'s
  own source) — before running the test.

This is deliberately **not** the old watchdog/checkpoint-at-an-arbitrary-time-limit chained
architecture (documented elsewhere in this research effort, which never completed one clean
end-to-end run across 16+ iterations, mostly from `SIGKILL`ing `xcodebuild` mid-write and
corrupting a partially-linked framework). Here, job 1's checkpoint always comes from a build that
finished **on its own**, never one cut off mid-link — so that specific corruption mode doesn't
apply. The one real, explicitly flagged, still-unverified assumption carried over from that
earlier work is whether Xcode's incremental build trusts a checkpoint restored on a different
VM/job at all; the mitigation (touching every restored file's mtime to "now", after the fresh
source checkout) is the same one used before. If it's wrong, the downside is just some wasted
incremental rebuild time in job 2, not a broken or corrupted build.

Both jobs are configured with `timeout-minutes: 358` (same backstop as before); confirmed
`productDir()` (`Tools/Scripts/webkitdirs.pm`) is the single shared function behind every build
step and `run-api-tests`, so job 1 and job 2 genuinely point at the same `WebKitBuild/Debug`
regardless of which scheme/script built into it.

**Honest status: this split is reasoned from reading WebKit's real build scripts and scheme
files, not yet proven by a run.** It should be more likely to fit within GitHub's per-job cap than
the single-job version (job 1 excludes several multi-GB targets the single-job version didn't
need), but neither job has actually executed yet in this form.

## v3 (2026-11-03): v2's job 1 ALSO didn't fit in ~6 hours — core build itself now split across
## 3 chained phases, 4 jobs total

The user ran v2 for real. `build-core` — the narrower "Everything up to WebKit" scheme, with
TestWebKitAPI/MiniBrowser/etc. already excluded — still didn't finish: it was cancelled at 5h58m,
annotated `The job has exceeded the maximum execution time of 5h58m0s`, build still in progress.
This is real, direct evidence that the core WebKit engine alone needs more than one GitHub Actions
job's ~6-hour hard cap on this hardware. (GitHub's hosted macOS arm64 runners have only 3 CPUs,
confirmed via GitHub's own `github-hosted-runners` docs — this is a genuinely CPU-bound build, not
unnecessary scope.)

**v3 splits the core build itself across three chained, checkpointed phases, then a fourth job
builds + runs the test on top of the finished core**:
`build-core-phase1` → `build-core-phase2` → `build-core-phase3` → `build-tests-and-run`.

This is not a new, untested idea. It specifically ports over the fixes a separate, much longer
WebKit PoC effort in this same research engagement (targeting a different bug, `FrameInfoData`
content forgery rather than this report's `frameID`-identity bug) arrived at only after **16
iterations** of a chained/checkpointed build failing in different ways — wrong build command,
masked failures, disk-tarball retention, CodeSign corruption from killing a build mid-write,
CodeSign corruption from a *resumed* build re-linking an already-fine restored bundle, and a
watchdog-vs-hard-timeout margin gap specific to restore-heavy jobs. Every one of those fixes is
carried into this package's `scripts/`:

- **`scripts/watchdog_build.sh`** — runs a build command in its own process group with an internal
  time budget. If the budget is hit, sends `SIGTERM` to the whole group first (not `SIGKILL`),
  waits up to 90 seconds for a clean exit, and only escalates to `SIGKILL` if it's still alive —
  giving an in-flight compile/link/codesign step a real chance to finish instead of being caught
  mid-write. A genuine build failure (non-zero exit on its own, not from the watchdog) fails the
  step for real; a deliberate on-budget stop does not — this is the fix for a real "masked
  failures" bug where an earlier, cruder version's unconditional `exit 0` let a genuine build
  regression go unnoticed for a full round of CI runs.
- **`scripts/verify_and_repair.sh`** — after a phase's build stops, runs
  `codesign --verify --deep --strict=all` on every `.framework`/`.xpc`/`.app` and discards any that
  fail verification, so the next phase rebuilds just that one piece instead of trusting a file that
  was caught mid-write by *this* phase's own watchdog.
- **`scripts/clear_stale_products.sh`** — before *resuming* a build from a restored checkpoint,
  unconditionally discards every already-linked/signed `.framework`/`.xpc`/`.app`/executable sitting
  directly under `WebKitBuild/Debug`, while leaving the far more expensive compiled `.o` files and
  Xcode's own build-plan state completely untouched. This is the fix for a real failure, reproduced
  twice in the sibling engagement, where the resumed build itself — not the previous phase's stop —
  corrupted an already-fine restored bundle by re-linking/re-signing it.
- **`scripts/checkpoint.sh` / `scripts/restore_checkpoint.sh`** — checkpoint the **whole**
  `WebKitBuild/` directory, not just `WebKitBuild/Debug`. Confirmed by reading
  `Tools/Scripts/webkitdirs.pm` directly (the `$baseProductDir/XCBuildData/...` glob) that Xcode's
  own incremental-build state, `WebKitBuild/XCBuildData/`, lives as a **sibling** of
  `WebKitBuild/Debug`, not inside it. An earlier draft of this v3 package (and v1/v2 of this same
  PoC) only checkpointed `WebKitBuild/Debug` — caught and fixed locally, with a scripted round-trip
  test (fake build tree, real tar/extract/clear), before this package was ever sent; checkpointing
  only `Debug` would have silently discarded the compiled-object and build-plan state a multi-phase
  chain exists to preserve, so later phases would never have actually progressed past wherever
  phase 1 reached, no matter how many phases were chained.
- Restore-heavy phases get a smaller internal watchdog budget (270 minutes) than phase 1's
  from-scratch budget (300 minutes) — the 30 minutes held back is reserved specifically for the
  download+extract+clear overhead that only restore-heavy phases pay. This is the fix for a real
  "margin gap" failure in the sibling engagement where a restore-heavy phase was cancelled by
  GitHub's own hard timeout with zero checkpoint produced, because its watchdog was set to the same
  budget as a from-scratch phase without accounting for the extra overhead.
- Every restore/extract/clear operation is itself wrapped in `scripts/run_with_deadline.sh`, which
  fails loudly (`::error::` + non-zero exit) if it doesn't finish within its own bound — so if
  something stalls, the log says exactly what and how long, instead of just "the job got
  cancelled."

**Budget math**: phase 1 gets a 300-minute internal watchdog (the same number already proven safe,
twice, for an equivalent from-scratch phase in the sibling engagement); phase 2 and phase 3 each
get 270 minutes. Cumulative core-build budget across the three phases: ~14 hours — comfortably
above the ~11-12 hours you said the full build realistically needs. If phase 3 still hasn't
finished the core build on its own by the time its own watchdog fires, `build-tests-and-run`
doesn't silently run the test against a half-built WebKit — `build-api-tests` will fail to link
against the incomplete core, and the existing "Interpret results" step reports that as
`INCONCLUSIVE`, not a false `NOT_REPRODUCED`.

**Tested locally, for real, before shipping** (this environment still has no macOS/Xcode
toolchain, so none of this substitutes for an actual WebKit build, but the chaining *mechanism*
itself is no longer just reasoned-about):
- `watchdog_build.sh`: verified a fast-succeeding command reports `completed`/exit 0; a
  fast-failing command reports `failed`/exit 1 (this caught a real bug — an earlier draft's
  `tee`-pipeline swallowed the real command's exit code, exactly the "masked failure" pattern this
  script exists to prevent, fixed with `set -o pipefail` inside the backgrounded subshell before
  this was ever sent); and a genuinely slow command actually gets `SIGTERM`'d at its budget and
  reports `watchdog_stopped`/exit 0.
- `run_with_deadline.sh`: verified a genuinely slow operation actually gets killed and the script
  exits 1 with a loud `::error::`.
- `checkpoint.sh` → `restore_checkpoint.sh` → `clear_stale_products.sh`: verified end-to-end
  against a synthetic fake `WebKitBuild/` tree (a `.framework`, an `.app`, a loose executable under
  `Debug/`, plus sibling `XCBuildData/` and `*.build/` directories standing in for real Xcode
  build-plan/intermediate-object state) that the whole tree round-trips through tar/extract
  correctly, and that `clear_stale_products.sh` removes only the `Debug/`-level bundles/executable
  while leaving the `XCBuildData/`/`*.build/` siblings completely untouched.
- `verify_and_repair.sh`: verified against the same fake tree that unsigned/fake bundles are
  correctly detected and removed (not a meaningful signature-correctness test without real
  codesign-signed output, but confirms the detection-and-removal logic itself runs correctly).

None of this is a substitute for a real multi-phase run — only an actual CI run can show whether
~14 hours of chained budget is actually enough, and whether the carried-over fixes hold up against
a build this specific ("Everything up to WebKit" only, not "+ Tools") rather than the one they were
originally proven against. Still scoped to one of the four vulnerable call sites
(`runJavaScriptAlert`) only. No bounty category or amount is claimed.

## v3 real run (2026-11-06): phase1 succeeded, phase2 failed on a packaging bug — fixed

The user ran the v3 4-job chain for real. Two pieces of real evidence came back, one good, one a
genuine bug on my end:

- **`build-core-phase1` succeeded** in 5h22m — consistent with its 300-minute internal watchdog
  firing plus setup/clone/verify/checkpoint/upload overhead. Its "Verify & repair" step (the v11
  fix, carried over from the sibling engagement) fired as designed and did real, useful work: it
  caught 4 bundles that came out broken from the watchdog's SIGTERM/SIGKILL stop
  (`com.apple.WebKit.WebContent.EnhancedSecurity.xpc`, `JavaScriptCore.framework`,
  `com.apple.WebKit.GPU.xpc`, `_WebKit_SwiftUI.framework`) and removed them so phase2 would relink
  them cleanly instead of trusting a half-written file — exactly its job.
- **`build-core-phase2` failed immediately** (18m54s, almost all of it spent re-fetching the
  commit and downloading phase1's checkpoint) in the "Restore the checkpoint" step:
  `scripts/restore_checkpoint.sh: line 18: scripts/run_with_deadline.sh: Permission denied`.

**Root cause: a real packaging bug, not a logic bug.** `restore_checkpoint.sh` and
`clear_stale_products.sh` invoked `scripts/run_with_deadline.sh` directly (relying on its
executable bit) instead of via `bash scripts/run_with_deadline.sh` the way every top-level step in
`poc.yml` already correctly invokes every script. I never explicitly set the executable bit on the
scripts before zipping this package, and whatever happened in the zip → unzip → `git add` → GitHub
checkout round trip, the bit didn't survive onto `run_with_deadline.sh` by the time phase2 ran —
so the direct invocation failed with a permission error before anything build-related even started.
This cost the user a wasted phase1 run (phase2's own failure doesn't invalidate phase1's actual
build progress, but phase2 never got to use it).

**Fix**: changed both call sites to `bash scripts/run_with_deadline.sh ...`, which runs correctly
regardless of the file's permission bits — removing the dependency entirely rather than just
re-setting the bit and hoping it survives packaging again. Verified the fix by reproducing the
exact failure locally first (stripped the executable bit from every script in a fresh test copy,
confirmed `restore_checkpoint.sh` failed with the identical `Permission denied` error), then
confirmed both fixed scripts complete successfully under that same no-exec-bit condition —
`restore_checkpoint.sh` against a real tar/extract round trip, `clear_stale_products.sh` against a
synthetic build tree, confirming it still only clears `Debug/`-level bundles and leaves
`*.build/`-sibling `.o` files untouched. All scripts in this package also now ship with the
executable bit set directly, as defense in depth — but the code no longer depends on it.

## v3 second real run (2026-11-07): all 3 core phases succeeded for the first time — final job hit two real bugs, both fixed

The user ran the exec-bit-fixed chain for real a second time. This is the best result this
engagement has gotten in its entire multi-week history:

- **`build-core-phase1`, `build-core-phase2`, and `build-core-phase3` all succeeded** — 5h20m,
  4h47m, 5h4m respectively (~15h25m total). The checkpoint/restore/resume mechanism worked exactly
  as designed across all three legs. The full WebKit core (WTF/JSC/WebCore/WebKit) is now a
  genuinely finished, verified build sitting in `build-core-phase3`'s checkpoint artifact.
- **`build-tests-and-run` failed**, in 13m10s, but on real, instructive evidence rather than
  packaging mistakes — two separate bugs, both confirmed directly from the user's uploaded
  `build-tests.log`/`test.log` rather than guessed from screenshots:

**Bug 1 — a genuine compile error.** The old final job ran `Tools/Scripts/build-api-tests --debug`
(a standalone build of `TestWebKitAPI.xcodeproj` on its own, outside the main `WebKit.xcworkspace`
context). That failed for real:
```
.../Tools/TestWebKitAPI/config.h:69:10: error: 'JavaScriptCore/JSExportMacros.h' file not found
note: Did not find header 'JSExportMacros.h' in framework 'JavaScriptCore' (loaded from
  '.../MacOSX26.5.sdk/System/Library/Frameworks')
```
Built standalone, clang resolved `JavaScriptCore` against the SDK's system framework (no private
headers) instead of the one phases 1-3 had just built locally, so the private header TestWebKitAPI
needs was never found. **Fix**: switched the final job's build step to `Tools/Scripts/build-webkit
--debug` — the same full-workspace scheme that compiled this exact source tree cleanly with zero
errors in the very first (v1) run of this whole engagement. WTF/JSC/WebCore/WebKit are already
built by phases 1-3, so this relies on Xcode's own incremental build to do only the remaining
delta (TestWebKitAPI + MiniBrowser/SwiftBrowser/gtest, which that scheme also happens to include —
there's no narrower workspace scheme that builds TestWebKitAPI alone). Run through the same proven
`watchdog_build.sh` wrapper, 270-minute budget.

**Bug 2 — the test step ran despite the build having failed.** The job summary showed
`build_status=` (empty) and the "Run the PoC test" step ran anyway. Root cause: GitHub Actions runs
`run:` steps under `bash --noprofile --norc -eo pipefail {0}` by default — `-e` is already active
even with no explicit `set -e` in the script. The old build step's script died the instant its
pipeline failed, before it reached the line that writes `build_status` to `$GITHUB_OUTPUT` — so
that output was simply never set. The next step's gate, `steps.build_tests.outputs.build_status ==
'0'`, then spuriously evaluated **true**: GitHub Actions expressions coerce both sides of `==` to
numbers when types differ, and `null` (an unset output) coerces to `0`, same as the string `'0'` —
so `undefined == '0'` is true. **Fix**: the build step now goes through `watchdog_build.sh`, which
writes its `build_outcome`/`build_exit_code` outputs unconditionally near the end of the script
(immune to this failure mode), and the test step's gate now compares against the non-numeric
string `'completed'` instead of `'0'` — a string that coerces to `NaN`, not `0`, so an unset output
can never spuriously match it. Added `set +e`/`set -e` guards around the test step's own fallible
pipeline too, as defense against the same bug class recurring there.

**Status at the time: reasoned and evidenced, not yet itself run.** Both fixes were backed by
direct evidence (the real compile error; the real empty `build_status`) and by strong precedent
(v1's own run already proved `build-webkit --debug` compiles this exact tree cleanly). The
output-gating fix has since been confirmed correct by a real run (next section) — the
`build-webkit --debug` switch has not, for a different reason than expected.

## v3 third real run (2026-11-09): all 4 jobs went green for the first time ever — but the final
## job's own 270-minute watchdog ran out before finishing, because "Everything up to WebKit +
## Tools" turned out to be a much bigger scheme than its name suggests

User ran the fixed chain for real. This is the best result yet: **`build-core-phase1`,
`build-core-phase2`, `build-core-phase3`, and `build-tests-and-run` all finished green** — no
CodeSign failure, no spurious test run, no silent failure masking. The job summary correctly
printed `RESULT: INCONCLUSIVE — the build did not finish within its 270-minute watchdog budget`
rather than a false CONFIRMED or a crash — i.e. the control-flow fix from the previous round
(gating the test step on `build_outcome == 'completed'`, immune to GitHub's null-coercion bug) is
now confirmed correct by a real run, for the first time.

**But the build itself didn't finish, and reading the real 64MB `build-tests.log` the user
uploaded showed why, directly — not from a screenshot, from the actual `xcodebuild` invocation
line and the full list of targets it started touching.** The build step's own command-line
invocation line confirms it really did run `-scheme "Everything up to WebKit + Tools"` as
intended, but that scheme is dramatically bigger than its name suggests or than this package's
own earlier comments assumed. In the ~270 minutes available, the log shows real, started work on:
TestWebKitAPI itself (good, that's the target that was needed) but also MiniBrowser,
MobileMiniBrowser, SwiftBrowser.app, DumpRenderTree, WebKitTestRunner, lldbWebKitTester, over a
dozen separate libwebrtc codec/support libraries (`yuv`, `yasm`, `webm`, `vpx`, `srtp`, `opus`,
`boringssl`, `aom`, `absl`, `libwebrtc.dylib`, and more), `dav1d` (a video codec) and its fuzzer,
ANGLE's shader translator, WebGPU's `wgslfuzz` fuzzer, over ten standalone JavaScriptCore test
tools (`testapi`, `testb3`, `testmasm`, `testdfg`, `testair`, `testmem`, `testRegExp`,
`testwasmdebugger`, `dynbench`, `minidom`, `mya`), `gtest`'s own framework, and several WebKit
daemons (`webpushd`, `webpushtool`, `adattributiond`). None of these are needed for the one
`SiteIsolation` test this PoC runs. By the time the 270-minute watchdog fired, the build was still
mid-way through relinking/re-emitting the Swift module for the `WebKit` framework target itself —
it had not yet reached a finished `TestWebKitAPI` binary. (Checked directly: zero `error:` lines
anywhere in the 64MB log, so this was genuinely a time problem, not a second compile bug.)

**Fix: go back to the narrower `Tools/Scripts/build-api-tests` route from two rounds ago, but this
time fix the actual cause of its original failure directly, instead of routing around it with a
bigger scheme.** That route's `'JavaScriptCore/JSExportMacros.h' file not found` error happened
because building the `TestWebKitAPI` project/scheme on its own doesn't make Xcode aware that
`JavaScriptCore` should resolve to the just-built local framework in `WebKitBuild/Debug` rather
than the SDK's own copy — confirmed by reading `Tools/Scripts/webkitdirs.pm`'s `XcodeOptions()`
and `buildXcodeScheme()` directly: `-workspace` and the correct `SYMROOT`/`OBJROOT` are already
passed by default, but nothing automatically adds `WebKitBuild/Debug` to
`FRAMEWORK_SEARCH_PATHS` for a project-level scheme that doesn't list `JavaScriptCore.xcodeproj`
as one of its own build dependencies. The build step now passes that search path explicitly:
```
Tools/Scripts/build-api-tests --debug 'FRAMEWORK_SEARCH_PATHS=<workspace>/wk/WebKitBuild/Debug $(inherited)'
```
(`$(inherited)` keeps whatever search paths the project already had, so this only adds a path, it
doesn't replace any). Verified the shell/Perl argument plumbing locally (not just read): simulated
exactly how GitHub Actions' `${{ github.workspace }}` substitution interacts with the single-quoting
needed to stop bash from trying to execute `$(inherited)` as a command substitution, and confirmed
`buildXcodeScheme`'s `system "xcodebuild", "-scheme", $scheme, @extraOptions` call (Perl's list-form
`system`, which bypasses the shell entirely) passes the whole `KEY=value with spaces` override
through as a single argument, exactly as xcodebuild expects. Kept the same 270-minute watchdog
budget, same job structure, same gating logic — this is a one-line change to what gets built, not
a new design.

## v3 fourth real run (2026-11-10): the FRAMEWORK_SEARCH_PATHS fix worked for JavaScriptCore —
## then a fast, real compile error (not a timeout) exposed a second, different bug: this job's own
## "Clear stale final build products" step was deleting WebKit.framework before this job's build
## ever had a chance to use it

User ran the fixed chain. Phases 1-3 succeeded again (5h23m, 4h59m, 5h9m — third clean run of the
core build in a row). `build-tests-and-run` this time failed **fast** — 23m31s, a real compile
error, not a timeout — which is itself progress: reading the real 1.2MB `build-tests.log`
confirms the `JSExportMacros.h` error from two rounds ago is completely gone (zero mentions in the
log), and the xcodebuild invocation line confirms the `FRAMEWORK_SEARCH_PATHS` override was
applied exactly as intended. That part of the fix works.

But a new, structurally identical error appeared for a different framework:
```
PlatformUtilities.h:33:10: fatal error: 'WebKit/WKNativeEvent.h' file not found
note: did not find header 'WKNativeEvent.h' in framework 'WebKit' (loaded from
  '.../MacOSX26.5.sdk/System/Library/Frameworks')
```
Same pattern as before (resolving to the SDK's copy instead of the local one), but this time for
`WebKit.framework` itself, which the `FRAMEWORK_SEARCH_PATHS` override should also cover since it
points at the whole `WebKitBuild/Debug` directory. The real cause turned out to be a conflict
between two parts of this package added in different rounds, not a third search-path gap: this
job's own "Clear stale final build products before resuming" step (added back in the v15 round of
the sibling engagement, ported into this package's v3 design, and still correctly needed in
phases 2 and 3) unconditionally deletes every `.framework`/`.xpc`/`.app` bundle under
`WebKitBuild/Debug` right after the checkpoint restore — including `WebKit.framework` — on the
theory that the upcoming build step will cleanly relink everything it just removed. That's true
for phases 2 and 3, whose build command (`build-webkit --only="Everything up to WebKit"`) really
does relink the whole core. It is **not** true for this job, whose build command
(`build-api-tests`, scoped to just the `TestWebKitAPI` scheme) only *links against* the core
frameworks as pre-built dependencies — it never rebuilds them. So this step was deleting
`WebKit.framework` and then handing control to a build that has no way to put it back, guaranteeing
this exact failure every time, regardless of the search-path fix.

**Fix**: removed the "Clear stale final build products" step from this job only (phases 2 and 3
keep it unchanged, where it's correctly matched to their build command). This is safe, not just
convenient: phase 3 already runs its own verify-and-repair pass immediately before checkpointing,
so the checkpoint this job restores is already known to be free of anything phase 3's own watchdog
might have left broken — there is nothing left for this job to usefully clear, and the thing it
was clearing is exactly what this job's build needs and cannot replace.

## v3 fifth real run (2026-11-12): removing the stale-product-clearing step worked (WebKit.framework
## error gone) -- but the SAME JavaScriptCore header error from two rounds ago came back, for a
## single target (`WebProcessPlugIn`) that the first `FRAMEWORK_SEARCH_PATHS` fix didn't reach

User ran the fixed chain again. Phases 1-3 succeeded a third time in a row (5h24m, 5h5m, 3h48m).
`build-tests-and-run` failed again, fast (14m53s, a real compile error) -- and reading the real
1.2MB `build-tests.log` confirms real progress: the `WebKit/WKNativeEvent.h` error from last round
is completely gone, confirming the stale-product-clearing removal fixed exactly what it was meant
to. But the *original* `JavaScriptCore/JSExportMacros.h` error from two rounds ago reappeared --
this time only for one target, `WebProcessPlugIn` (an injected-bundle plugin that gets loaded into
the WebContent process, built as part of the same `TestWebKitAPI` scheme, sharing the same
`config.h`), while every other target built past that same header line cleanly.

Rather than guess why one target behaves differently, read that target's own
`Tools/TestWebKitAPI/Configurations/WebProcessPlugIn.xcconfig` and the shared
`Configurations/Base.xcconfig` directly. Neither sets `FRAMEWORK_SEARCH_PATHS` itself, so there's
no project-level setting directly fighting the override -- but `Base.xcconfig` showed the
project's own established pattern for "add another place to find frameworks" on macOS is a literal
`-iframework <path>` flag baked into `OTHER_CFLAGS[sdk=macosx*]`, not `FRAMEWORK_SEARCH_PATHS` at
all. Also confirmed, by grepping `config.h` and the `PlatformUtilities.h` header involved in the
*previous* round's error, that the only framework-style (`<Framework/Header.h>`) imports anywhere
in this shared code are `JavaScriptCore`, `WebKit`, `Foundation`, and `Cocoa` -- the last two are
genuine system frameworks that were never in question, so there is no third framework lurking.

**Fix**: add the same local path via `OTHER_CFLAGS` and `OTHER_CPLUSPLUSFLAGS` (as an explicit
`-F`/`-iframework` pair, mirroring the project's own pattern for this exact kind of override)
in addition to keeping `FRAMEWORK_SEARCH_PATHS` -- not instead of it. This is deliberately
redundant: two independently-mechanized ways to tell every target in the scheme where the
already-built frameworks are, so a target that for whatever reason doesn't fully pick up one of
them should still pick up the other. Verified the shell/GitHub-Actions quoting for the two new
multi-word, `$(inherited)`-containing overrides the same way as the first one (simulated the
exact post-substitution bash parse), confirmed each lands as a single, correct argument.

## v3 sixth real run (2026-11-13): the OTHER_CFLAGS/OTHER_CPLUSPLUSFLAGS fix from last round did
## NOT work -- identical error, same two files, same line -- real root cause found this time by
## reading clang's own framework-search behavior, not guessed; a fast (no-compiling) diagnostic
## step added so the NEXT run produces hard evidence either way, in minutes, not another full cycle

User ran the OTHER_CFLAGS/OTHER_CPLUSPLUSFLAGS fix. Phases 1-3 succeeded again. `build-tests-and-run`
failed again, in 15m59s, with the *exact same* error as the round before it: both occurrences of
`config.h:69:10: error: 'JavaScriptCore/JSExportMacros.h' file not found (in target
'WebProcessPlugIn' from project 'TestWebKitAPI')`, resolving against the SDK's header-less copy,
unchanged down to the line number. The fix did not do anything for this target.

Read the real `build-tests.log` directly to find out why, instead of writing a third blind guess:

- **The override was genuinely present and correctly formed.** Grepped the log for the actual
  `xcodebuild` invocation line and the exported build settings: `FRAMEWORK_SEARCH_PATHS`,
  `OTHER_CFLAGS`, and `OTHER_CPLUSPLUSFLAGS` all show up exactly as intended, each with our
  `-F`/`-iframework ${{ github.workspace }}/wk/WebKitBuild/Debug` correctly appended. So this
  wasn't a quoting or plumbing failure like some earlier rounds -- the setting really does reach
  xcodebuild's own resolved build settings.
- **The real clang invocation for the two failing files doesn't show `-F`/`-iframework` directly on
  the command line at all** -- it reads its per-target flags from a response file
  (`@.../common-args.resp`) that Xcode's build system writes to disk and clang reads silently; that
  file's contents never get echoed into the text log, so its content still can't be inspected
  directly from what the user can upload.
- **The most likely real cause, reasoned from how clang itself resolves `<Framework/Header.h>`
  imports**: clang's framework search walks the search-path list in order and locks onto the FIRST
  directory where it finds a framework bundle of the right name -- if that first one lacks the
  header, clang does not keep looking at later search-path entries for a different same-named
  framework. Both `FRAMEWORK_SEARCH_PATHS` and the previous `OTHER_CFLAGS`/`OTHER_CPLUSPLUSFLAGS`
  fix put our path via `$(inherited) <our path>` or (for `FRAMEWORK_SEARCH_PATHS`) `<our path>
  $(inherited)` -- inconsistently. Whichever inherited system/SDK framework path already finds a
  header-less `JavaScriptCore.framework` first in the final order wins, regardless of our path
  being present somewhere else in the list.

**Fix**: all three overrides now put our local `WebKitBuild/Debug` path FIRST, before
`$(inherited)`, consistently -- `FRAMEWORK_SEARCH_PATHS` already had this order (which is exactly
why it worked for the main target); `OTHER_CFLAGS`/`OTHER_CPLUSPLUSFLAGS` previously had it
backwards and are now corrected to match. Verified the shell/GitHub-Actions quoting for the
reordered strings the same way as every previous override (simulated the post-substitution bash
parse): each still lands as one correct argument, `$(inherited)` still literal, not expanded.

**Also added, specifically so the next run doesn't cost another full cycle to learn the same
amount again**: `scripts/diagnose_webprocessplugin.sh`, a new step that runs right after the
checkpoint restore and before the real build, in well under a minute (it does not compile
anything). It directly checks, on disk, whether the restored checkpoint's `JavaScriptCore.framework`
and `WebKit.framework` actually have their private headers at all, and runs a real
`xcodebuild -showBuildSettings -target WebProcessPlugIn` (same workspace/scheme/overrides as the
real build, just the settings-only action) to print exactly what FRAMEWORK_SEARCH_PATHS/
OTHER_CFLAGS/OTHER_CPLUSPLUSFLAGS/SYSTEM_FRAMEWORK_SEARCH_PATHS/HEADER_SEARCH_PATHS resolve to for
this exact target, with our overrides applied -- real evidence, not another log excerpt to guess
from after the fact. Always runs (`if: always()`), uploaded as `diagnose-webprocessplugin.log`
regardless of what the real build does afterward.

**Two real bugs in the new diagnostic script were caught by actually running it locally before
shipping it, not assumed correct from reading it**: (1) its output-log path was computed as a
relative path *before* `cd`-ing into the build directory, so writes after the `cd` resolved to a
nonexistent `wk/wk/...` location -- fixed by computing it after the `cd`, relative to the new cwd,
matching how every other script in this package (`watchdog_build.sh` included) takes its log path.
(2) the settings-grep step read from and appended to the same log file in one pipeline
(`grep ... "$out_log" >> "$out_log"`), which `grep` correctly refuses with "input file is also the
output" -- fixed by capturing the grep's result into a variable first, then appending that.
Re-tested against a synthetic build tree (fake frameworks with/without the private headers in
different places, and a fake `xcodebuild` that prints its own received argv) and confirmed: file
existence is reported correctly either way, the real `xcodebuild` invocation's three overrides each
arrive as one correctly-formed argument with `$(inherited)` intact, and the script always exits 0
(never fails the job on its own) whether or not `xcodebuild` itself is even present.

**Honest status (2026-11-13)**: the reordering fix is reasoned from a real, specific mechanism (how
clang resolves framework-style imports), not a blind restatement of the previous attempt -- but
whether it's actually sufficient for this target is still unknown until a real run says so, exactly
like every fix in this package before it. What's different this time is that the run is no longer
all-or-nothing: even if the reorder doesn't fix it, the new diagnostic step means the very next log
will show, directly, whether the restored checkpoint's frameworks have the needed headers on disk
at all and what xcodebuild itself resolves these settings to for this one target -- turning the
next failure (if there is one) into hard evidence instead of the same blind spot a third time.

## v3 seventh real run (2026-11-15): the JSExportMacros/WebProcessPlugIn fix is CONFIRMED working
## (zero recurrence) -- but a new, deeper root cause surfaced: the core checkpoint reaching this
## job can be missing whole frameworks, not just a header inside one. The diagnostic step from
## last round caught it directly, on disk, instead of only in a compile error. Architecture changed
## so this job no longer trusts the checkpoint blindly.

User ran the reordering fix. Real, important good news first: **the JavaScriptCore/JSExportMacros
error that affected WebProcessPlugIn for two rounds straight is gone -- zero mentions anywhere in
this run's 7500-line build-tests.log.** Putting the local path before `$(inherited)` in
`OTHER_CFLAGS`/`OTHER_CPLUSPLUSFLAGS`, matching the one override that was already known to work,
was the right fix for that specific problem, and this run proves it, not just reasons it.

The run still failed overall, though -- in 15m39s, the same fast-failure shape as the last two
rounds, but on a *different* error this time: `fatal error: 'WebKit/WKNativeEvent.h' file not
found`, hit while Clang's module dependency scanner tries to build the `TestWebKitAPILibrary`
Swift/ObjC interop module (`PlatformUtilities.h:33`, imported from a `.swift` file via a generated
module map) -- not inside `WebProcessPlugIn` this time, a different target entirely, hitting the
same `WebKit/` framework-style import. Everything downstream cascaded from this one failure
(`unable to resolve module dependency: 'TestWebKitAPILibrary'`, then `'WebKit_Private'`), exactly
the domino-effect shape a single blocked module import produces -- not several independent causes.

**This time the new `diagnose_webprocessplugin.sh` step (added last round specifically so a failure
wouldn't come back empty-handed) answered the question directly, on disk, before the build even
ran**: `WebKitBuild/Debug/JavaScriptCore.framework` and `WebKitBuild/Debug/WebKit.framework` were
**entirely absent** from the checkpoint restored from `build-core-phase3` -- not present-but-
missing-a-private-header, not there at all. `find` on both paths returned "No such file or
directory." That diagnostic step's own `xcodebuild -showBuildSettings -target WebProcessPlugIn`
sub-check separately failed with a real, unrelated usage error (`xcodebuild: error: You cannot
specify targets with a workspace` -- `-target` and `-workspace` can't be combined; a genuine bug in
that diagnostic script, caught by this real run since there was no way to test an actual
`xcodebuild` invocation locally) -- but the file-existence check, the part that mattered, had
already given a direct, unambiguous answer by the time that second check even ran.

**This fully explains the `WebKit/WKNativeEvent.h` error without needing to theorize about search
paths at all: there is no framework there to search inside.** No `FRAMEWORK_SEARCH_PATHS`/
`OTHER_CFLAGS` override, however it's ordered, can make a header resolve inside a framework bundle
that was never linked in the first place. The whole "clang locks onto the first framework it
finds" theory from last round was aimed at the wrong layer of the problem for this new error --
it's not that the wrong copy of the framework gets found first, it's that *no* copy of it exists in
the checkpoint this job restores.

**Most likely explanation, consistent with everything already known about this architecture**:
`build-core-phase3`'s own internal watchdog most likely fired before the "Everything up to WebKit"
build it runs had fully finished linking/signing every framework -- and whichever of
`JavaScriptCore.framework`/`WebKit.framework` was still mid-write at that exact moment got
correctly discarded by that phase's own "Verify & repair" step (the v11 fix, working as intended)
as broken rather than trusted. `build-core-phase3` still shows green in the run summary because a
deliberate watchdog stop is correctly treated as success, not failure (the v3-package "masked
failures" fix) -- but green there has never guaranteed the core finished 100%, only that nothing
*failed outright*. Nothing after that point in the chain ever gets a chance to relink what was
discarded, because this job's build command (`build-api-tests`) was deliberately chosen to never
rebuild these frameworks at all -- that assumption, reasonable when the checkpoint really is
complete, has no fallback when it isn't.

**Fix: `build-tests-and-run` no longer trusts the checkpoint blindly.** Restructured this job so it
can no longer be silently defeated by an incomplete checkpoint, in three concrete changes:
1. `scripts/check_core_complete.sh` (replacing the half-broken `diagnose_webprocessplugin.sh`,
   keeping only the part of it that worked): a fast, no-compiling step, right after the checkpoint
   restore, that reports directly whether the core frameworks are actually present -- informational
   only, so the next step's expected running time is never a surprise either way.
2. "Clear stale final build products before resuming" is back in this job (removed two rounds ago
   for the opposite reason -- it was unconditionally deleting a framework a *narrower* build would
   never relink). It's safe here now because of change 3.
3. The build step goes back to the exact same, already-proven `Tools/Scripts/build-webkit --debug
   --only="Everything up to WebKit"` command phases 1-3 use -- not the narrower `build-api-tests`.
   If the checkpoint genuinely is complete, Xcode's own incremental build confirms there's nothing
   to do almost immediately. If it isn't, this step actually finishes the missing work itself,
   inside its own 240-minute watchdog, before anything touches TestWebKitAPI. Only once this step
   reports `build_outcome == completed` does a new, separate, short-watchdog (60m) step run the
   narrower `build-api-tests` to produce the actual test target -- now safely, since the core it's
   linking against was just verified complete rather than assumed complete. "Interpret results" and
   "Upload logs" were both updated to distinguish failures in the core-finishing step from failures
   in the TestWebKitAPI-build step, so a future failure says plainly which one it was instead of a
   single blended signal.

Re-verified both patches still apply cleanly against the pristine pinned commit (unchanged this
round -- only `poc.yml` and the scripts changed). Re-validated `check_core_complete.sh` against two
synthetic trees (one with both frameworks' private headers present, one with both frameworks
entirely absent, matching exactly what this run's diagnostic showed) and confirmed it reports the
right verdict either way and always exits 0. Re-validated the YAML parses.

## v3 eighth real run (2026-11-16): the self-healing step worked exactly as designed and made
## real, measured progress -- but 240 minutes wasn't enough to finish both frameworks. One of
## them, confirmed fixed; the other, confirmed still in progress, zero compile errors either way.
## Added a dedicated fourth core-build phase so this work gets its own full budget instead of
## sharing one with the TestWebKitAPI build and the test.

User ran the self-healing `build-tests-and-run` restructure for real. All four jobs finished green
again, in 19h53m47s total. This run produced the clearest evidence yet that the architecture itself
is sound -- not another guess-and-check round, a real measurement of exactly how much work is left
and where.

**`core-completeness-check.log` confirmed the same finding as last round, not a new one**: both
`JavaScriptCore.framework` and `WebKit.framework` were still entirely absent from this run's
restored `build-core-phase3` checkpoint (`find` on both: "No such file or directory"). Consistent
with the "a phase's own watchdog fires mid-link and verify-and-repair correctly discards the
casualty" explanation -- and this run's own job-level annotations go further than any previous run
in pinning down *where*: `build-core-phase1: wk/WebKitBuild/Debug/com.apple.WebKit.WebContent.
EnhancedSecurity.xpc failed codesign verification -- removing so the next phase relinks it` and
`build-core-phase1: wk/WebKitBuild/Debug/JavaScriptCore.framework failed codesign verification --
removing so the next phase relinks it`. **This directly implicates `build-core-phase1`**, not
phase2 or phase3, as the origin of at least the JavaScriptCore.framework corruption. It does not
yet explain why phase2 and phase3 -- which both run the exact same full build command and should
relink anything phase1 left broken -- don't end up fixing it before their own checkpoints are
taken; that half of the question is still open (see below).

**`build-core-finish.log` -- 67.8MB, 205,989 lines -- is the real find this round.** Read in full,
not sampled:
- **Zero `error:` lines anywhere in the file.** Whatever this step did for its full 240-minute
  budget, it was not failing -- it was still working when time ran out.
- **`JavaScriptCore.framework` was fully relinked and code-signed**: a real `Ld` step followed by a
  real `CodeSign` step for it, both completing successfully, confirmed directly at specific lines
  in the log. The framework the completeness check found missing at the start of this job was
  genuinely, successfully rebuilt by this step, inside its budget.
- **`WebKit.framework` never reached its own link step.** By the time the 240-minute watchdog fired,
  the log's tail shows the build still mid-way through `SwiftCompile` on WebKit's own Swift overlay
  sources -- real, forward progress, just not far enough along yet to reach `Ld`/`CodeSign` for this
  framework too.

Put together: this is not a bug. It's a correctly-functioning self-healing step that had two
multi-GB frameworks to rebuild and a time budget sized for roughly one of them. The job summary
correctly reported `RESULT: INCONCLUSIVE -- finishing the core build did not fit in its 240-minute
watchdog budget`, exactly as it should.

**Fix: added a dedicated `build-core-phase4` job**, inserted between `build-core-phase3` and
`build-tests-and-run`, identical in shape to phase2/phase3 (downloads and restores phase3's
checkpoint, clears stale final build products, resumes the same proven `"Everything up to WebKit"`
build under its own 270-minute watchdog, verifies/repairs, then checkpoints and uploads its own
artifact). `build-tests-and-run` now consumes phase4's checkpoint instead of phase3's directly. Its
own self-healing core-completeness check/clear/rebuild steps stay in place unchanged -- they're now
a second-chance safety net behind phase4's dedicated budget rather than the only thing standing
between an incomplete checkpoint and a wasted run, exactly the layered-defense shape that's worked
for every other failure mode in this package so far. Cumulative core-build watchdog budget across
all four phases: 300 + 270 + 270 + 270 = 1110 minutes (~18.5 hours).

Re-validated the full YAML parses and confirmed the job dependency chain is exactly
`build-core-phase1 -> build-core-phase2 -> build-core-phase3 -> build-core-phase4 ->
build-tests-and-run` (checked programmatically, not by eye, given this package's recurring
colon-in-an-unquoted-scalar YAML bug). Re-verified both patches still apply cleanly together against
the pristine pinned commit, and all scripts still pass `bash -n` with their executable bits set.

**Status: reasoned directly from this round's own measured evidence, not yet itself run.** Unlike
earlier rounds, this fix isn't a new theory being tried after a failure -- it's a straightforward
budget increase, directly sized against a real log that showed exactly how much work was left
(one framework fully done, a second one started but not finished, zero errors). The open question
about *why* phase1's output needs repairing in the first place, and why phase2/phase3 don't
re-fix it, remains unresolved either way.

## v3 ninth real run (2026-11-18/19): all four core-build phases went green in one run for the
## first time ever -- confirming build-core-phase4 -- but build-tests-and-run still came back
## INCONCLUSIVE, with both frameworks absent again. Reading the log line by line around
## JavaScriptCore.framework's own successful CodeSign step surfaced a likely real root cause in
## our own verify_and_repair.sh, not in the WebKit build itself.

User ran the 5-job chain for real twice in a row (run `44174966008`). The first attempt got all
four core-build phases green (5h35m/5h9m/5h7m/5h5m) -- the first time this report's PoC has ever
gotten phase1 through phase4 all green in one run -- but `build-tests-and-run` itself never
started: GitHub Actions failed to acquire a hosted runner for it ("The job was not acquired by
Runner of type hosted even after multiple attempts"), alongside a top-level "Internal server
error." Both are GitHub Actions platform-side failures -- nothing in this package's own logs or
annotations points at a cause here, and the fix was operational, not a code change: re-running just
the failed job ("Re-run failed jobs," which correctly reused phase1-4's already-uploaded
checkpoints rather than redoing ~21 hours of work) got a runner on the second attempt and ran to
completion in 4h22m.

**That completed run still reported `RESULT: INCONCLUSIVE` — finishing the core build did not fit
in its 240-minute watchdog budget — with `core-completeness-check.log` showing the identical
finding as every previous round: both `JavaScriptCore.framework` and `WebKit.framework` entirely
absent at the start of the job**, despite phase4 having just spent 5+ hours on exactly that work.
Zero `error:` lines anywhere in the 204,512-line `build-core-finish.log` (not a compile bug), and
the log's tail shows real incremental progress -- further into `WebKit.framework`'s own
resource-copy/asset-catalog/SwiftDriver steps than the eighth run reached. But the repeated, total
absence of a framework that multiple rounds' worth of logs show being successfully built is what
this round finally root-caused, by reading the log immediately **after**
`JavaScriptCore.framework`'s own apparently-successful build sequence (`Ld`, `CodeSign`,
`RegisterExecutionPolicyException`, `Touch`, zero errors, the build moving on to other targets):

**A separate target — `'All'`, an aggregate target in the `JavaScriptCore` Xcode project — runs a
script phase named "Copy jsc into JavaScriptCore.framework" that writes a new file
(`Versions/A/Helpers/jsc`) into the bundle immediately afterward, i.e. *after* the framework was
already signed and sealed.** This is normal, Apple-authored behavior, not corruption — WebKit's own
build settings list that exact phase name right next to `"Work around 109484516"` (an Apple radar
number) in `EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES`, meaning Apple's own engineers already
treat this phase as a known special case. But adding a file to a bundle after it's signed
invalidates the bundle-level resource envelope that `scripts/verify_and_repair.sh` was checking
with `codesign --verify --deep --strict=all` run on the whole bundle *directory* — which means that
script has very likely been discarding a perfectly good, fully-built, correctly-signed
`JavaScriptCore.framework` on every single run since this package's very first version, mistaking
Apple's own normal post-build step for watchdog-induced corruption. That would explain why this
framework (and possibly `EnhancedSecurity.xpc`, flagged as failing verification in this exact run
too) has kept coming back "entirely missing" at the start of every phase, independent of how much
watchdog budget or how many phases have been given — because no amount of extra time helps if the
very next step after finishing the framework throws it away again.

**Fix: `scripts/verify_and_repair.sh` no longer runs codesign against the whole bundle directory.**
It now resolves each bundle's own main executable — `Versions/A/<Name>` for a `.framework`, the one
file under `Contents/MacOS/` for a `.xpc`/`.app` — and verifies that file directly. A plain Mach-O
file has no resource envelope of its own, so this is unaffected by a legitimate script phase adding
unrelated files elsewhere in the bundle, but it still correctly fails on a binary actually truncated
by a watchdog `SIGTERM`/`SIGKILL` landing mid-link or mid-sign, which is the real failure this
script exists to catch. **Tested locally** (this environment has no real macOS/codesign, so this
tests the script's own logic, not real signature verification) against five synthetic bundles: a
framework with a valid binary *plus* an extra post-signing file and a stale seal (simulating the
real "Copy jsc…" case) is now correctly **kept**; a framework with no binary at all, and an `.xpc`
with a genuinely corrupt binary, are both still correctly **removed**; bundles with ordinary valid
binaries are kept. The workflow YAML was also re-validated this round with `actionlint` (new this
round — catches real GitHub Actions errors, like malformed expressions or bad `needs:` references,
that `bash -n`/`yaml.safe_load` can't), on top of the usual chain-order check, a patch dry-run
against the pristine pinned commit, and `bash -n` on every script.

**Second change, independent of the fix above**: the core-build chain is widened from 4 phases to
9 (`build-core-phase1` through `build-core-phase9`), each still its own fresh 270-minute watchdog
(phase1 keeps 300), for more total margin while the fix above is confirmed for real. This is
additional insurance, not a replacement for the fix — if the false-positive theory is the whole
story, most of phases 5-9 may end up finishing almost instantly (nothing left to rebuild); if it
isn't, they're real additional budget. Both changes ship together this round; an honest open
question until a real run reports back is how much each one actually contributed.

**Honest status (2026-11-19/20): still no real run has reached the actual `SiteIsolation` test.**
This is the first round where the recurring "framework keeps vanishing" mystery has a specific,
directly-observed mechanism behind it rather than a general "watchdog timing" theory — but it is
reasoned from a real log, not yet confirmed by a real run with the fix applied. No bounty category
or amount claimed; nothing drafted or posted to Apple's portal.

## v4 real run (tenth run, 2026-11-22/23): the main-binary codesign fix did NOT work either — same
## two bundles discarded, same clean zero-error build underneath them — so this round abandons
## codesign entirely for this check, instead of trying a third variation of asking it the same
## question. Also: the actual fix for "this is taking too long."

User ran the full 9-phase, 10-job v4 chain for real. All ten jobs went green — no CodeSign
corruption, no packaging bug, no masked failure — but it took **2 days 2 hours 25 minutes** of
wall-clock time, and the job summary still read `RESULT: INCONCLUSIVE`, with
`core-completeness-check.log` showing the identical finding as every round before it: both
`JavaScriptCore.framework` and `EnhancedSecurity.xpc` absent. This round's job annotations go
further than before, though, because they now carry the v4 fix's own wording: `build-core-phase1:
wk/WebKitBuild/Debug/JavaScriptCore.framework failed codesign verification on its main binary
(wk/WebKitBuild/Debug/JavaScriptCore.framework/Versions/A/JavaScriptCore) -- removing...`. That
confirms the v4 fix's code genuinely ran — this is not the old whole-bundle check misfiring again —
and it still discarded the framework anyway.

Reading `build-core-finish.log` directly removed any remaining doubt about which side of this is
wrong. For the third straight round, `JavaScriptCore.framework` goes through a completely clean,
zero-error `Ld` → `CodeSign` → `RegisterExecutionPolicyException` → `Touch` sequence, at almost the
exact same log line as the two previous rounds, with the build moving straight on to other targets
right after. Every piece of real evidence — the build log, twice now under two different
`codesign` invocations — says this binary is fine. `codesign --verify` disagrees, on a framework
that's signed ad-hoc (`codesign --force --sign - --timestamp=none ...`, confirmed directly in the
log as "Signing Identity: Sign to Run Locally"), even when pointed at the one file directly instead
of the whole bundle.

**Fix: stop asking `codesign` about this at all.** The actual question `verify_and_repair.sh` needs
answered — "did a watchdog `SIGTERM`/`SIGKILL` truncate this file mid-write" — doesn't need a
cryptographic signature check in the first place: a binary truncated mid-write will not be a
structurally valid Mach-O file, full stop, independent of any signing state. The script now reads
each bundle's main binary's own first four bytes and checks them against the real Mach-O/fat-binary
magic numbers (`feedface`/`feedfacf`/`cefaedfe`/`cffaedfe`/`cafebabe`/`bebafeca`) instead of calling
`codesign` at all. **Tested locally** against six synthetic bundles: a framework with a valid-magic
binary plus an unrelated extra file written into the bundle afterward (the real "Copy jsc..."
scenario that the v4 fix was aimed at) is correctly **kept**; a bundle with no binary, one with a
zero-byte binary, and one with non-Mach-O garbage content are all correctly **removed**; a
fat-binary-magic framework is correctly **kept**. This doesn't prove the real build's binaries will
pass — this environment still has no macOS/codesign — but it no longer depends on a tool that has
now produced two independent false positives on a provably-good file in this exact environment.

**Second, independent change — the actual answer to "this takes too long," not another round of
adding more phases and hoping:** the user's instruction this round was explicit about rejecting more
guessed time budgets and demanding the real bottleneck get found. Two concrete architectural changes
follow from that, not just another number:

1. **Every phase, and `build-tests-and-run`'s own catch-up step, now checks whether the core is
   already complete *before* spending any watchdog budget on it, and skips the build step entirely
   if so.** `scripts/check_core_complete.sh` now also writes `core_complete=true`/`false` to
   `$GITHUB_OUTPUT` (checking each framework's own main binary — the same definition
   `verify_and_repair.sh` uses), and `poc.yml` conditions each phase's build step on
   `steps.corecheck.outputs.core_complete != 'true'`. Concretely: once the core genuinely finishes,
   every phase after that point costs minutes (checkout, restore, a fast completeness check,
   checkpoint, upload), not another multi-hour watchdog window spent confirming there's nothing left
   to do. This replaces a fixed phase count that was either not enough (most of this report's
   history) or — as this very round showed, 9 phases for the same result as 4 — needlessly long,
   with a chain that does only as much work as is actually left.
2. **The phase ceiling itself is brought back down from 9 to 5.** This is a reasoned, *not yet
   proven* guess at a safer margin, not a claim that 5 is exactly right — now that
   `verify_and_repair.sh` no longer wastes part of every phase re-discarding a framework that was
   never actually broken, the core should need meaningfully less wall-clock time than the 15-20
   hours phases 1-4 alone have taken in every past round, but there's no real-CI evidence yet for
   exactly how much less. If 5 isn't enough, the symptom is the same honest `INCONCLUSIVE` this
   package has always reported, not a silently hidden gap — and because of change 1, the cost of
   being wrong in either direction is now small.

**Tested locally before shipping, same discipline as every round**: `check_core_complete.sh`'s new
`core_complete` output against four synthetic cases (both main binaries present → `true`; one
missing → `false`; both missing, matching this round's real log → `false`; the workdir itself
missing → no output written at all, which fails safe — the YAML's `!= 'true'` check treats "unknown"
the same as "not done," never as a false skip). The regenerated `poc.yml` was validated
programmatically (job chain, `needs:`, `timeout-minutes`, artifact upload/download name agreement,
and every new `if:` condition, including the compound ones on `build-tests-and-run`'s `buildtests`/
verify/test steps) rather than by eye — this package has hit the same colon-inside-an-unquoted-
YAML-scalar bug before, and did again while drafting this round's step names, caught by
`yaml.safe_load` before it ever reached a commit. Re-ran `actionlint` (downloaded fresh, as before);
the only finding is the same `macos-26` "unknown runner label" warning every previous round has
gotten, which is a stale label list in the linter itself, not a real error — this exact label has
executed real jobs on real GitHub Actions infrastructure throughout this report's whole history.
Re-verified both patches still apply cleanly — not just "unchanged so presumably fine," but a real
`git apply --check` + `git apply` against a cached real WebKit checkout at the exact pinned commit,
reproducing `fetch_webkit.sh`'s own sequence exactly. All ten scripts re-pass `bash -n` with their
755 exec bits intact.

**Honest status (2026-11-23): this is a different, more fundamental fix than the last one, not a
third variation of it — but like every fix in this package's history, tested locally is not the
same as proven by a real run.** What's actually confirmed by real CI so far: the core-build chain
mechanism itself works (phases reliably go green); `JavaScriptCore.framework`'s own build is
reliably clean and error-free; `codesign --verify` is unreliable on this specific ad-hoc-signed
output, confirmed under two independent invocations. What's still unconfirmed: whether a Mach-O
magic-number check succeeds where codesign didn't; whether 5 phases plus the skip logic actually
finishes the core meaningfully faster than the ~2 days this round took; and, unchanged since this
report's very first PoC attempt, whether the `SiteIsolation` test itself passes, fails, or times
out — no run has ever reached that step. No bounty category or amount is claimed.

## What this does NOT (yet) claim

- **Neither this round's fix (Mach-O magic-number check, replacing codesign entirely) nor the
  skip-if-already-complete logic nor the reduced 5-phase ceiling have been run in CI yet.** All
  three are a direct, evidence-based response to the tenth real run (codesign independently
  misfiring twice on a binary the build log shows is genuinely fine, plus the user's explicit
  instruction to find the real bottleneck instead of adding more guessed time) -- not a new theory
  tried with no evidence behind it. But exactly like every fix before it in this package, reasoned
  from real evidence is not the same as proven by a real run of this exact form.
- **Confirmed, not assumed, by real runs**: the JavaScriptCore/JSExportMacros error that affected
  WebProcessPlugIn is fixed (zero recurrence across every run since); the self-healing restructure
  of `build-tests-and-run` works exactly as designed; `build-core-phase4` (and by extension, the
  core-build chain mechanism itself) reliably goes green; and, as of the tenth run,
  **`codesign --verify` is confirmed unreliable on this package's ad-hoc-signed build output**,
  under two independently-reasoned invocations (whole-bundle, then main-binary-only) that both
  flagged a framework the build log shows going through a completely clean, zero-error
  `Ld`/`CodeSign` sequence. None of these need to be revisited regardless of how the next run goes.
- **Reasoned and locally tested, not yet confirmed by a real run**: that checking a binary's own
  Mach-O magic number, instead of asking codesign anything, correctly distinguishes a watchdog-
  truncated file from Apple's own legitimate post-signing script phases. The local synthetic tests
  (six cases, see above) exercise the script's logic, not real codesign-signed macOS output, since
  this environment has no macOS toolchain -- the same limitation every fix in this package has had
  from the start.
- Phases 1-4 are proven to go green together end-to-end for real (ninth run, 2026-11-18/19) -- but
  "the job shows green" has never meant "the core build genuinely finished 100% before its
  watchdog fired," only that nothing failed outright. The reduced phase5 (replacing the untested
  phase5-9 from the previous round) and the new skip-logic on phases 2-5 and on
  `build-tests-and-run`'s catch-up step have not had a real run. The `RESULT:` line `poc.yml`
  prints is only meaningful once the final job's build genuinely reaches
  `build_outcome == 'completed'` (or the core was already complete going in).
- Only one of the four vulnerable call sites (`runJavaScriptAlert`) is covered. `runJavaScriptConfirm`,
  `runJavaScriptPrompt`, and `runOpenPanel` are structurally identical and would need their own
  small patches/tests (same technique, same `patches/0001-*.patch` approach) — a natural next step
  once this one is confirmed, not attempted here to keep the first CI run's scope and cost down.
- `runBeforeUnloadConfirmPanel` (the one correct sibling) is not exercised here as a negative
  control; its sender lives in different code (navigation/frame-loader client, not
  `WebChromeClient`) and would need separately-traced instrumentation.
- Per this engagement's standing rule, no bounty category or amount is claimed or predicted.

## How to run it

1. Push this repo (including `.github/workflows/poc.yml` and `scripts/`) to any GitHub repository
   you control.
2. Trigger the workflow manually (`workflow_dispatch` — it will never fire on a push, since this is
   a many-hour, 6-job chain).
3. The six jobs run one after another (`needs:`), not in parallel — `build-core-phase1` →
   `build-core-phase2` → ... → `build-core-phase5` → `build-tests-and-run`. **Phase2 onward, and
   `build-tests-and-run`'s own catch-up step, each check first whether the core is already complete
   and skip their build step entirely if so** (see `scripts/check_core_complete.sh`) — so a phase
   that finds nothing left to do should finish in minutes (checkout, restore, the fast completeness
   check, checkpoint, upload), not another multi-hour watchdog window. Real runs so far (against the
   previous, codesign-based verification fix, now believed to have been discarding good output every
   round) have taken roughly 5 hours per phase that did real build work; how much of the 5-phase
   ceiling actually gets used for real work this round is one of the open questions a real run would
   answer. If GitHub Actions fails to acquire a runner for one job (a platform-side issue, not
   something in this package — seen once, in the ninth real run), use "Re-run failed jobs" rather
   than restarting the whole chain; it correctly reuses already-uploaded checkpoints instead of
   redoing finished phases.
4. Each `build-core-phase*` job uploads its own checkpoint artifact
   (`webkitbuild-phase1-checkpoint`, etc.) plus its own build log, whether it succeeds or fails, so
   if something goes wrong partway through the chain there's still something to look at. The final
   job uploads `poc-logs-tests-and-run` (`core-completeness-check.log`, `build-core-finish.log`,
   `build-apitests.log`, `test.log`).
5. The job summary and the final "Interpret results" step (in `build-tests-and-run`) print one of
   `RESULT: CONFIRMED`, `RESULT: NOT_REPRODUCED`, or `RESULT: INCONCLUSIVE`. Please report back
   which one, plus — if you can get them, not just screenshots — the actual log files: whichever
   `build-phase*.log` files exist (so if a phase's build genuinely failed partway through the chain,
   rather than just running out of its own watchdog budget, that's visible directly) and the final
   job's `core-completeness-check.log`/`build-core-finish.log`/`build-apitests.log`/`test.log`.

## Suggested reply to Apple once (and only once) this comes back CONFIRMED

Don't post anything to the portal until a real run actually says `RESULT: CONFIRMED` — as of the
tenth real run (2026-11-22/23), it hasn't yet: every run so far has gone green on build setup and
checkpointing but the actual `SiteIsolation` test itself has never been reached, let alone executed.
Once a run does reach it and reports CONFIRMED, a short, honest reply along these lines (edit to
match the actual log output):

> Thank you — here's a reproduction against a real, compiled WebKit Debug build with Site
> Isolation enabled (GitHub Actions macOS runner, WebKit commit 86af064084e1cfd66a11252d75c14808c1196a5c).
> A new TestWebKitAPI test (`SiteIsolation.FrameIdentitySpoofingPoC_AlertAttributedToFrameWhoseProcessDidNotSendMessage`)
> loads a top-level page and a cross-origin iframe that genuinely land in two different WebContent
> processes (confirmed via `_processIdentifier`), then has the iframe's own process send the real
> `RunJavaScriptAlert` IPC message naming the main frame's `FrameIdentifier` instead of its own —
> the one field a compromised renderer process would need to forge; everything else, including the
> message's own origin info, is left real. The resulting `WKFrameInfo` the app receives correctly
> reports the dialog's origin as the iframe's (`webkit.org`), but incorrectly reports
> `isMainFrame = YES` and the main frame's own process identifier — i.e. the dialog is attributed
> to a frame whose process did not send the message, exactly as requested. The one line of
> instrumentation needed to forge the `frameID` (not `frameInfo`) is disclosed and commented in the
> attached patch; everything downstream is stock WebKit. Build and test logs attached.

## Files in this package

- `patches/0001-sender-instrumentation-alert-frame-spoof.patch` — the disclosed, `IPC_TESTING_API`-gated
  sender-side stand-in in `WebChromeClient::runJavaScriptAlert`.
- `patches/0002-test-addition-frame-spoof.patch` — the new `SiteIsolation` test.
- `.github/workflows/poc.yml` — the 6-job chain: 5 checkpointed core-build phases (each skipping its
  own build step once the core is already complete), then a job that self-checks the core, finishes
  it if needed, builds `TestWebKitAPI`, and runs the test.
- `scripts/select_xcode.sh`, `scripts/free_disk_space.sh`, `scripts/fetch_webkit.sh` — ordinary
  per-job setup (select the newest available Xcode; clean up unused preinstalled SDKs/simulators;
  shallow-clone WebKit at the pinned commit and apply both patches).
- `scripts/watchdog_build.sh` — runs a build command with an internal, graceful (`SIGTERM`-first)
  time budget; used by all five core-build phases (when not skipped) plus the final job's own
  core-finishing and TestWebKitAPI-build steps.
- `scripts/verify_and_repair.sh` — verifies each `.framework`/`.xpc`/`.app`'s own main binary
  directly against the real Mach-O/fat-binary magic numbers (as of this round — no `codesign` call
  at all; see the "v4 real run (tenth run)" section above for why two independent codesign-based
  checks both misfired on provably-good output) and discards the bundle if that binary is missing or
  not a structurally valid Mach-O file.
- `scripts/clear_stale_products.sh` — discards already-linked/signed build products (keeping
  compiled `.o` files and Xcode's build-plan state) before a phase resumes from a restored
  checkpoint.
- `scripts/checkpoint.sh` / `scripts/restore_checkpoint.sh` — tar/untar the whole `WebKitBuild/`
  directory between jobs, via `actions/upload-artifact`/`download-artifact`.
- `scripts/check_core_complete.sh` — fast, no-compiling check, run by every restore-capable job
  (phase2 onward, and the final job) right after restoring its checkpoint, that reports whether the
  core frameworks' own main binaries are actually present and (as of this round) writes
  `core_complete=true`/`false` to `$GITHUB_OUTPUT` so `poc.yml` can skip that job's build step
  entirely when there's genuinely nothing left to do.
- `scripts/run_with_deadline.sh` — a stricter version of the watchdog used for the restore/clear
  bookkeeping steps, where taking too long is itself a real problem.
- This `README.md`.
