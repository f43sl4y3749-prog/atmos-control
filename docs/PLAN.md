# Plan: `atmos-control` — system-wide personalized Spatial Audio with full renderer controls (macOS 26, Apple Silicon)

## Context

The user wants a macOS app that **replaces the stock audio output**, runs all system audio
through **Apple's spatial/Atmos rendering engine *with the user's personalization*** (ear-scan
HRTF + AirPods head tracking), while exposing the **full set of spatial-renderer settings** —
unlike the OS, which offers a single on/off toggle.

Target environment (verified on this machine): **macOS 26.5.1 (Tahoe), Apple Silicon (arm64),
AirPods Pro 3.** Greenfield project (`~/dev/atmos-control`, empty,
not a git repo).

This plan was produced after a deep technical research pass (18 agents) whose riskiest feasibility
claims were **adversarially verified against the installed macOS 26.5 SDK headers**. The corrected
facts below are load-bearing — several "obvious" assumptions turned out wrong (exact property IDs,
multichannel tap capability, and the legal impossibility of decoding real Atmos).

### Locked scope decisions (from user)
1. **All apps, system-wide** → virtual HAL driver (`AudioServerPlugIn`) + companion daemon.
2. **Personal / open-source** → self-sign + fast iteration; no Mac App Store, notarization optional.
3. **Positioning: "Spatial Audio / personalized binaural"** — `atmos-control` is the internal
   codename only. We do **not** claim Dolby Atmos decoding (legally/technically out of reach without
   a Dolby license).
4. **System audio only for MVP** — no ADM BWF file player, but keep the renderer abstraction open
   so it can be added later.

---

## Feasibility verdict (the honest framing)

| User goal | Verdict | Why |
|---|---|---|
| Replace stock output for all apps | ✅ **Yes** | `AudioServerPlugIn` HAL plugin + daemon = the only Apple-supported "virtual default output" path. |
| Use Apple's *personalized* render | ✅ **Yes, as a tenant** | We run **our own** `AUSpatialMixer`; with two entitlements the OS applies the user's personalized HRTF + AirPods head-tracking *inside it*. We get an **enable switch, never the HRTF data**. There is **no** public API to force Apple's *system* spatializer onto other apps. |
| Full set of Atmos-renderer settings | ⚠️ **Full *spatial-renderer* surface, not Dolby's** | We expose the entire `AUSpatialMixer` property/parameter set + a Dolby-Renderer-style monitoring/downmix/binaural-distance UI we build ourselves. We **cannot** decode Atmos objects (no Dolby license) and **never receive** object metadata — system apps hand CoreAudio already-decoded **PCM (usually stereo)**. |

**Net product:** a **system-wide, personalized, head-tracked binaural spatializer/upmixer with a full
manual control surface** — the same Apple DSP engine that powers Spatial Audio, but driven by us with
knobs the OS hides. It is **not** a Dolby Atmos decoder; that framing must stay out of the UI/marketing.

---

## Recommended architecture

Four components. This is the eqMac / Rogue Amoeba SoundSource pattern.

### 1. Virtual output device — `AudioServerPlugIn` (Core Audio HAL plugin)
- CFPlugin `.driver` bundle in `/Library/Audio/Plug-Ins/HAL`, hosted out-of-process by `coreaudiod`.
  Confirmed the **only** supported purely-virtual-output path; `AudioDriverKit` entitlements are
  denied for non-hardware devices.
- Base on Apple's **NullAudio** sample (the HAL-plugin sample — *not* the older IOKit
  `SimpleAudioDriver`) and/or **BlackHole** (proves up to 256ch, 32-bit float).
- Implements `AudioServerPlugInDriverInterface`; IO ops `kAudioServerPlugInIOOperationReadInput`
  (`'read'`), `kAudioServerPlugInIOOperationWriteMix` (`'rite'`).
- Expose a **12-channel 7.1.4, 32-bit-float** stream via `kAudioDevicePropertyStreamConfiguration` /
  `AudioStreamBasicDescription`, matching coreaudiod's mix format. (Most app audio arrives as stereo
  PCM — the 12-ch capability is for apps that *do* emit multichannel and for our internal bed.)

### 2. Default-device control (in the app/daemon)
- Set the virtual device as default: `AudioObjectSetPropertyData(kAudioObjectSystemObject, …)` with
  `kAudioHardwarePropertyDefaultOutputDevice` (+ `kAudioHardwarePropertyDefaultSystemOutputDevice`
  for system sounds), scope `kAudioObjectPropertyScopeGlobal`, element
  `kAudioObjectPropertyElementMain`. **No entitlement.** Observe changes with
  `AudioObjectAddPropertyListenerBlock`.

### 3. Companion daemon (privileged helper)
- Installed via `SMAppService` (launchd); survives app quit.
- Reads the virtual device's captured PCM (shared-memory ring buffer) → renders → writes to the
  **real** output device. (An `AudioServerPlugIn` cannot itself output to hardware; the daemon
  bridges. Optionally bind virtual+real with a CoreAudio aggregate/multi-output device.)

### 4. Renderer — `AUSpatialMixer` (`kAudioUnitType_Mixer` `'aumx'` / subtype `'3dem'`)
Run in the daemon's real-time render callback (lower overhead than `AVAudioEngine`).
- Per-input: `kAudioUnitProperty_SpatializationAlgorithm = kSpatializationAlgorithm_UseOutputType`.
- Global: `kAudioUnitProperty_SpatialMixerOutputType` (**3100**) = `…_Headphones`.
  ⚠️ **Output type alone does not enable binaural** — it must be paired with the `UseOutputType`
  algorithm (or legacy `_HRTF` / `_HRTFHQ`).
- Bed bus: `kAudioUnitProperty_SpatialMixerSourceMode = …_AmbienceBed` for the 7.1.4 bed;
  `…_PointSource` for synthetic object buses.
- Head tracking: `kAudioUnitProperty_SpatialMixerEnableHeadTracking` (**3111**, macOS 12.3+) —
  auto-bound to AirPods, no manual CoreMotion feed needed.
- Personalization: `kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode` (**3113**, macOS 13+) =
  `_On`(1) or `_Auto`(2); read back
  `kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF` (**3116**, macOS 14+).

### 5. Control app — SwiftUI menu-bar app
Exposes the full settings surface (below), toggles the driver on/off, switches default device,
shows whether personalized HRTF actually engaged.

### Entitlements / signing (personal/open-source path)
- `com.apple.developer.spatial-audio.profile-access` — personalized HRTF (macOS 15+).
- `com.apple.developer.coremotion.head-pose` — head-tracked orientation (macOS 15+).
- `NSMotionUsageDescription` if touching `CMHeadphoneMotionManager` directly.
- ⚠️ **Open item:** these are *restricted* entitlements. Self-signed/free-account builds may **not**
  be granted them — `_Auto` falls back to **generic** HRTF for unentitled apps; `_On` may need a real
  provisioning profile from a paid Apple Developer account. **Phase 0 must confirm this before
  anything else** — it is the single biggest value-prop risk.

### Key corrected facts to carry into implementation (from SDK-header verification)
- `kAudioUnitProperty_SpatialMixerDistanceParams` = **3010** (NOT 3014).
- `…_SpatialMixerRenderingFlags` = 3003 (`InterAuralDelay`=1<<0, `DistanceAttenuation`=1<<2);
  `…_SpatialMixerAttenuationCurve` = 3013 (`_Power`/`_Exponential`/`_Inverse`/`_Linear`);
  `…_SpatialMixerPointSourceInHeadMode` = 3103. These are **legacy AU3DMixer props, unchanged in
  macOS 26** — not new.
- The **process-tap path CAN do multichannel** (only the *global convenience* initializers are
  mono/stereo): `initWithProcesses:andDeviceUID:withStream:` + `mixdown = NO` preserves channel
  count. Relevant only if we ever choose the tap fallback.
- macOS 26 adds a *new* spatial AU worth a spike: `kAudioUnitSubType_AUAudioMix` with
  `kAUAudioMixProperty_SpatialAudioMixMetadata` / `kAUAudioMixProperty_EnableSpatialization`
  (Cinematic framework / Audio Mix, WWDC25). Evaluate as a future renderer; **not** the MVP path.

---

## The "full settings" surface to expose (all public `AUSpatialMixer`, no entitlement for the props)

**Rendering / output**
- Output type: Headphones / Built-in / External speakers (`…_SpatialMixerOutputType` 3100).
- Algorithm: `UseOutputType` (default), `HRTF`, `HRTFHQ`, `SoundField`, `SphericalHead`,
  `EqualPowerPanning`, `StereoPassThrough`.
- Per-input source mode: `AmbienceBed`, `PointSource`, `SpatializeIfMono`, `Bypass`.

**Geometry / distance** (legacy props, verified IDs above)
- Rendering flags (inter-aural delay, distance attenuation), attenuation curve, distance params
  (`mReferenceDistance` / `mMaxDistance` / `mMaxAttenuation`), in-head mode.

**Per-input parameters** (Input scope, public/stable)
- `kSpatialMixerParam_`: `Azimuth`(0,±180°), `Elevation`(1°), `Distance`(2,m), `Gain`(3,dB),
  `PlaybackRate`(4), `Enable`(5), `MinGain`(6), `MaxGain`(7), `ReverbBlend`(8),
  `GlobalReverbGain`(9), `OcclusionAttenuation`(10), `ObstructionAttenuation`(11),
  `HeadYaw`/`HeadPitch`/`HeadRoll`.

**Personalization toggles**
- Enable head tracking (3111), Personalized-HRTF mode (3113), read-back "is personalized" (3116).

**Dolby-Renderer-style controls we implement ourselves** (our DSP, not Apple APIs)
- Monitoring / speaker-layout selection (2.0 … 9.1.6) via our own downmix matrices.
- Per-target trim & downmix, per-source "binaural distance" (Off/Near/Mid/Far) mapped onto the
  mixer's distance/algorithm, loudness metering, presets.

**Explicitly NOT achievable** (state in docs, never in UI as if available)
- Dolby Atmos object/JOC decode (needs licensed Dolby Consumer Decoder SDK).
- Dolby's certified binaural HRTF/room algorithm (proprietary).
- Object metadata / XYZ from system audio (we receive decoded PCM, not objects).
- Reading the user's HRTF coefficients / ear-scan / fused head-pose (only the raw
  `CMHeadphoneMotionManager` IMU stream is public).

---

## Risks & blockers (ranked)

1. **CRITICAL — restricted-entitlement grant for personal/self-signed builds.** If
   `spatial-audio.profile-access` can't be obtained, personalization degrades to generic HRTF. *De-risk
   in Phase 0.*
2. **HIGH — no App Store; needs installer + `coreaudiod` restart**
   (`launchctl kickstart -k system/com.apple.audio.coreaudiod`). Acceptable for personal/open-source.
3. **MEDIUM — captured signal is decoded PCM, usually stereo.** Caps perceived quality vs native
   Atmos; "7.1.4" only when apps emit multichannel or we synthesize a bed.
4. **MEDIUM — latency** of driver→daemon→render round-trip (IO buffer +
   `kAudioDevicePropertySafetyOffset` + presentation latency); head tracking feels worse with high
   latency. Measure empirically for 12-ch on Apple Silicon.
5. **MEDIUM — virtual default output vs OS head-tracking interaction.** Making a virtual device the
   default may disable the OS's own AirPods head-tracked path; we must own head tracking end-to-end.
   Verify on macOS 26.
6. **LOW — Dolby trademark.** Mitigated by the "Spatial Audio" positioning already chosen.

---

## Phased build plan

**Phase 0 — De-risk spike (do this first).** Minimal `AUSpatialMixer` harness fed by a test file.
Set `UseOutputType` + `Headphones` + `EnableHeadTracking` + `PersonalizedHRTFMode=_On`; request both
entitlements on a real provisioning profile. **Proves:** (a) the entitlements are obtainable on the
user's account, (b) personalized HRTF + head tracking actually engage on macOS 26 / AirPods Pro 3
(verify via property 3116). *This validates the entire value prop before building infrastructure.*

**Phase 1 — Virtual driver + daemon.** NullAudio/BlackHole-based `AudioServerPlugIn` (12-ch 7.1.4) +
`SMAppService` daemon + default-device switching. Daemon loops captured PCM straight to the real
device (no spatialization yet). **Proves:** true "replace system output" for all apps, install flow,
persistence, low-latency passthrough.

**Phase 2 — Insert the renderer.** Wire `AUSpatialMixer` into the daemon's render callback between
capture and real-device output. **Proves:** end-to-end personalized head-tracked spatialization of
all system audio.

**Phase 3 — Full settings UI + Dolby-style controls.** SwiftUI menu-bar app exposing the entire
parameter/property surface + our own downmix/trim/monitoring-layout/binaural-distance/metering +
presets. **Proves:** the "full settings" promise within legal bounds.

**Phase 4 — Hardening & future.** Latency tuning, device/AirPods hot-swap, head-tracking recenter.
Spike `AUAudioMix` (macOS 26) as a future renderer. Optionally add the ADM BWF file player.

---

## Verification (per phase, end-to-end)

- **Phase 0:** read `kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF` (3116) → must be
  true with entitlement; A/B listen with head tracking on/off (rotate head → soundstage stays fixed).
- **Phase 1:** `system_profiler SPAudioDataType` shows the virtual device; selecting it in Sound prefs
  routes all audio through it; daemon passthrough is audible with no dropouts; survives app quit.
- **Phase 2:** play stereo music → audibly binaural/externalized; head rotation tracks; confirm no
  double-spatialization with the OS toggle.
- **Phase 3:** each control audibly changes output; presets persist; "is personalized" indicator
  reflects reality.
- **Latency:** measure round-trip (loopback timing) at several buffer sizes; document the floor.

## Open items to confirm experimentally on macOS 26 (undocumented)
- Whether the two spatial entitlements are self-serve vs Apple-approved (Phase 0).
- Whether head-tracked personalized audio survives a third-party *virtual* default output (Phase 2).
- Measured 12-ch round-trip latency on Apple Silicon.
- Whether `AUAudioMix` is a better long-term renderer than `AUSpatialMixer`.

## First execution step next session
1. `git init` the repo; copy this plan to `docs/PLAN.md`.
2. Scaffold an Xcode workspace: `App` (SwiftUI menu-bar), `Driver` (AudioServerPlugIn bundle),
   `Daemon` (SMAppService helper), `SpatialEngine` (shared `AUSpatialMixer` wrapper, renderer
   abstraction kept open for ADM later).
3. Build the **Phase 0 spike** and confirm the entitlement/personalization reality before anything else.
