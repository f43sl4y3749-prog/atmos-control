// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "atmos-control",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        // Phase 0 de-risk spike: a CLI harness that instantiates AUSpatialMixer,
        // configures personalized + head-tracked binaural rendering, plays a test
        // signal to the current output device (AirPods), and reads back whether
        // personalized HRTF actually engaged (property 3116).
        .executableTarget(
            name: "Phase0Spike",
            path: "Sources/Phase0Spike"
        ),
        // Phase 1: audio passthrough daemon — reads from the atmos-control virtual
        // loopback device and plays out to a real output device (two HAL units +
        // lock-free ring buffer bridging the two clock domains).
        .executableTarget(
            name: "AtmosDaemon",
            path: "Sources/AtmosDaemon",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
