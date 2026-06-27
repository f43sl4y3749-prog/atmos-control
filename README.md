# atmos-control (internal codename)

System-wide **personalized, head-tracked binaural Spatial Audio** for macOS with a full
manual control surface over Apple's spatial renderer (`AUSpatialMixer`). Not a Dolby Atmos
decoder — a PCM spatializer/upmixer driven by the same Apple DSP engine that powers Spatial
Audio, exposing the knobs the OS hides.

- Target: macOS 26 (Tahoe), Apple Silicon, AirPods Pro 3.
- Full plan: [`docs/PLAN.md`](docs/PLAN.md).

## Status

**Phase 0 — de-risk spike.** Validating the single biggest assumption before building any
infrastructure: *does personalized HRTF + AirPods head tracking actually engage inside an
app-hosted `AUSpatialMixer`, and is it available to an unentitled/self-signed binary?*

```
swift run Phase0Spike            # play test tone through spatial mixer to default output
swift run Phase0Spike <file.wav> # spatialize a real audio file (subjective A/B listen test)
```

The spike prints whether `kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF`
(3116) reads true — the programmatic signal that the user's personal HRTF profile is in use.

## Architecture (planned)

1. `AudioServerPlugIn` virtual 12-ch (7.1.4) HAL output device — "replace stock output".
2. Default-device control (no entitlement).
3. `SMAppService` privileged daemon — bridges captured PCM → renderer → real device.
4. `AUSpatialMixer` renderer (personalized + head-tracked binaural).
5. SwiftUI menu-bar control app — the full settings surface.
