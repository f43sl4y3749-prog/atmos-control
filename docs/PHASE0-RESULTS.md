# Phase 0 — De-risk spike results

**Date:** 2026-06-27 · **Machine:** macOS 26.5.1 (25F80), Apple Silicon, AirPods Pro 3 ·
**Toolchain:** Command Line Tools only (no Xcode), Swift 6.3, SwiftPM · unentitled / ad-hoc.

Phase 0 goal: validate the core value proposition *before* building any infrastructure — does
Apple's `AUSpatialMixer`, driven by us, deliver personalized + head-tracked binaural audio, and
what does it require?

## Verdict: ✅ value proposition validated, #1 risk eliminated

| Question | Result |
|---|---|
| Does our own `AUSpatialMixer` render binaural to AirPods? | ✅ Yes |
| Does **personalized** HRTF engage? (property 3116) | ✅ **YES — every sample of a 25s run** |
| Does it need the `spatial-audio.profile-access` entitlement? | ❌ **No** — engaged on an unentitled CLT build |
| Does head tracking work? | ✅ Yes (subjective: soundstage stayed anchored on head rotation) |
| Does head tracking need `coremotion.head-pose`? | ❌ **No** — worked unentitled |
| Generic HRTF (no scan) on any headphones? | ✅ configures cleanly (`HRTF_MODE=off`) |
| Speaker virtualization? | ✅ configures cleanly (`OUTPUT_TYPE=builtin/external`) |

**Implication:** the renderer's full core + premium value works **with no paid Apple Developer
account, no restricted entitlements, and no Xcode** — at least in-process. This collapses the
project's original #1 risk.

Preconditions for personalization: output device = AirPods (registered to the Apple ID) + a scanned
Personalized Spatial Audio profile + `PersonalizedHRTFMode = On` (or Auto). Remove any of these and
it gracefully falls back to generic HRTF (still binaural).

## Key technical findings (load-bearing for all later phases)

1. **AVAudioEngine is unusable for `AUSpatialMixer` on macOS 26.5.1.** `engine.connect()` into the
   spatial mixer null-derefs inside AVFAudio `AVAudioNodeImplBase::DidConnectToMixer` (use of
   uninitialized memory; the deref address varies run-to-run). Proven via a 4-way parallel workflow:
   approaches A (ordering/realization) and B (explicit formats + prepare) were exhausted and *all*
   variants crashed or hung; reproduced standalone. **Not fixable** by connection ordering, formats,
   `prepare()`, element-count, or post-start connection.
   → **Use the raw AudioUnit render-callback graph everywhere** (`AudioComponentInstanceNew` +
   `kAudioUnitProperty_SetRenderCallback`), which is the production/daemon path anyway.

2. **`AVAudioEnvironmentNode` cannot do personalization.** It is an `AVAudioNode` (not `AVAudioUnit`),
   exposes no reachable `AudioComponentInstance`/v2 `audioUnit`, and the v3 `AUAudioUnit` has no bridge
   to SpatialMixer property IDs 3100/3111/3113/3116. So 3113 can't be set and 3116 can't be read.
   Dead end for our needs (confirmed negative result).

3. **Swift-6 real-time-thread gotcha.** In `main.swift`, top-level code is `@MainActor` by default, so
   a Swift `Array` closure (e.g. `withUnsafeBufferPointer`) used inside a `@convention(c)` audio
   render callback inherits `@MainActor` and **aborts on the HAL render thread**
   (`_swift_task_checkIsolatedSwift` / `dispatch_assert_queue`). Fix: hold sample data as a raw
   `UnsafeMutablePointer<Float>` and index it directly inside the callback — no isolated closures.

4. **Property facts re-verified against the SDK headers on this machine** (all confirmed): output
   type 3100 (Headphones=1/BuiltIn=2/External=3); EnableHeadTracking 3111; PersonalizedHRTFMode 3113
   (Off=0/On=1/Auto=2); AnyInputUsingPersonalizedHRTF 3116 (read-only); SpatializationAlgorithm
   UseOutputType=7; SourceMode 3005 PointSource=2; DistanceParams=3010. Header note line ~3003 confirms
   `PersonalizedHRTFMode` alone is insufficient — must pair with `UseOutputType` + `Headphones`.

## The spike

`Sources/Phase0Spike/main.swift` — raw-AU graph: `noise → [renderCB] → AUSpatialMixer →
[renderCB] → DefaultOutput → device`. Sets all 5 spatial properties (each verified via read-back),
sets per-input parameters, polls 3116 at 1 Hz, prints a tier-aware verdict. Env vars:
`OUTPUT_TYPE` / `HRTF_MODE` / `ALGO` / `SECONDS` / `SWEEP` (see README).

## Remaining unknown → Phase 2 gate

Does personalization + head tracking still engage when the renderer runs in the **launchd daemon**
(non-GUI process) reading from the **virtual HAL device** while that virtual device is the **system
default output**? Making a virtual device the default may disable the OS's AirPods head-tracked path,
so we must own head tracking end-to-end. Unproven until the driver + daemon exist (Phase 1), then
test (Phase 2).

## Next: Phase 1

Virtual `AudioServerPlugIn` HAL output device (12-ch 7.1.4) + `SMAppService` daemon + default-device
control; daemon loops captured PCM to the real device (no spatialization yet) to prove
"replace system output for all apps", install flow, persistence, low-latency passthrough.
