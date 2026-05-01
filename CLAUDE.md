# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run the app (requires device/emulator)
flutter analyze          # Static analysis (flutter_lints)
flutter test             # Run tests (cmake required for opencv_dart native build)
flutter test test/feature_format_test.dart  # Run a single test file
flutter build apk        # Build Android APK
flutter build ios        # Build iOS (requires Mac + Xcode)

bash scripts/sync_mall_assets.sh  # Refresh assets/mall/ from sign_surveyor
```

## Architecture

Flutter AR indoor navigation app for malls/buildings. Three tiers, auto-detected:

| Tier | Requirement | Screen | How it works |
|---|---|---|---|
| **1 — Full AR** | ARCore/ARKit | `ar_navigation_screen.dart` | `ar_flutter_plugin_2` renders 3D scene; `CoordinateAligner` maps AR world coords ↔ map coords |
| **2 — Sensor AR** | Gyroscope + magnetometer (no ARCore) | `sensor_ar_screen.dart` | Camera feed + PDR + scan-on-tap **visual localization** (ORB → solvePnP via `opencv_dart`) corrects drift |
| **3 — 2D Map** | Anything else | `map_2d_screen.dart` | Static 2D graph rendering with turn-by-turn directions |

Tier detection happens in `device_capability_checker.dart` → `NavigationTier` enum. `main.dart` routes to the right screen; Tier 2 is deferred-loaded to keep the camera/CV/isolate code out of Tier 1/3 builds.

### Mall data pipeline

The graph (nodes + edges) and shop metadata live in `assets/mall/shops.json`, produced by the sibling [`/Users/m.ead/apps/sign_surveyor`](../sign_surveyor) Python tool. Per-shop ORB feature files live in `assets/mall/features/<shop_id>.bin` (SSF1 binary format, ~5 KB each).

To add or update shops:
1. Run the surveyor on the new sign(s)
2. `bash scripts/sync_mall_assets.sh` (copies `shops.json` + `output/*.bin` here)
3. `flutter pub get` and rebuild

The schema declares `coordinateSystem: {units: meters, angleConvention: ccw_from_positive_x_degrees, angleRange: "[0, 360)"}` — `MallData.fromJson` enforces this at load time.

### Core Navigation System (`lib/ar_navigation_system.dart`)

Shared by all three tiers. Contains:

- **`Vector3`** — Lightweight 3D vector math (custom; no `==` override).
- **`NavGraph`** — A* pathfinding over weighted/directed waypoints; min-heap implementation.
- **`CoordinateAligner`** — Yaw-aware AR world ↔ map transform. Misalignment here breaks all Tier 1 navigation — trickiest part of the system.
- **`QRAnchorRegistry`** — Map QR code values → known map positions for Tier 1 alignment.
- **`AvatarGuide`** + **`NavigationSession`** — Walks an avatar along waypoints; ties graph + aligner + guide together.

### Visual Localization Stack (Tier 2)

Replaces the previous MindAR/WebView image tracker. Scan-on-tap: user picks a target shop, points the camera at its sign, taps the shutter, and the pipeline returns a fresh mall-frame position fix. PDR fills in between scans.

- **`lib/mall_data.dart`** — Typed schema mirroring `shops.json`. `MallData.loadFromAssets()` + lazy `loadFeaturesForShop()`.
- **`lib/feature_format.dart`** — Pure-Dart SSF1 binary reader (host-VM testable; no opencv_dart dependency).
- **`lib/mall_geometry.dart`** — **Single source of truth** for coordinate-frame math. `normalizeAngle`, `compassToMallHeading`, `signFrameToMallFrame`, `pdrStep`, `degToRad`, `radToDeg`. **Every coordinate convention change goes through this file.** Defines `kMallNorthOffsetDeg` (TODO: must be measured at the actual mall).
- **`lib/camera_intrinsics.dart`** + native channel `mall_nav/camera_intrinsics` (Android Kotlin in `MainActivity.kt`, iOS Swift in `AppDelegate.swift`) — fetches per-device fx/fy/cx/cy. Falls back to FOV-estimated intrinsics if native fails.
- **`lib/localization_service.dart`** — Wraps every `opencv_dart` call: ORB (params **identical** to surveyor: `nFeatures=500, scaleFactor=1.2, nLevels=8, edgeThreshold=15`, top-100 by response) → BFMatcher (NORM_HAMMING, Lowe ratio 0.75) → findHomography (RANSAC, 3px) → perspectiveTransform → solvePnP (SOLVEPNP_IPPE_SQUARE on the 4 sign corners) → sign frame → mall frame via `signFrameToMallFrame`. Sanity gates on Laplacian variance (blur), distance, and y-height.
- **`lib/isolate_localizer.dart`** — Long-lived isolate holding a singleton `LocalizationService`. ORB and BFMatcher are stateful native objects; recreating per scan would cost 50–150 ms — the isolate keeps them warm. JPEG bytes ride a `TransferableTypedData` for zero-copy.
- **`lib/debug_screen.dart`** — Developer-only screen, reachable via long-press on the home title (debug builds only). Live displays of compass raw vs mall heading, PDR position + last step delta, last solvePnP output, last frame Laplacian variance. Buttons: "Run self-test" (uses bundled images at `assets/mall/test_images/<shop_id>.jpg`) and "Log fix → ground truth" (appends JSONL to `getApplicationDocumentsDirectory()`).

### PDR Tracker (`lib/pdr_tracker.dart`)

Pedestrian Dead Reckoning — the position engine for Tier 2 between scans. Key design decisions:

- **Step detection state machine**: idle → rising → falling → valley → count. Smoothed accelerometer magnitude from `sensors_plus` `userAccelerometerEventStream` (gravity-free).
- **Walking lock**: requires `minConsecutiveSteps` (default 2) valid steps before counting position moves, preventing jitter from non-walking motion.
- **Compass smoothing**: circular mean over a rolling window; gates on `accuracy` to reject noisy indoor readings. Waits for `_headingMinSamplesForInit` samples before latching initial heading.
- **Direction**: only forward vs. lateral (half-step). Backward detection was removed — body-frame accelerometer sign is unreliable.
- **Step math**: `_computeNewPosition` calls `mall_geometry.pdrStep` so the displacement convention lives in one file. Compass→mall normalization uses `mall_geometry.normalizeAngle`.
- **Corrections**:
  - `correctPosition(Vector3)` — manual fix (called from arrival anchoring and the start-shop manual fallback).
  - `correctPositionAndHeading(Vector3, double mallHeadingDeg)` — visual fix; treats vision as ground truth on disagreement (re-anchors `_initialHeading` so the current compass reading maps to the supplied mall heading).
  - `snapToNodes(List<NavNode>)` — snaps to a candidate list (typically the path ahead).
- **Drift counters**: `stepsSinceLastFix` and `lastFixAt` reset on every fix. UI surfaces a warning after 20 steps with no fresh visual fix.

### State Management

No state management library. All state lives in `StatefulWidget`s with `setState()`. Cross-screen scan results are published via `DebugDataBus` (a tiny module-level `ValueNotifier` holder in `debug_screen.dart`).

### Key Dependencies

| Package | Purpose |
|---|---|
| `ar_flutter_plugin_2` | Tier 1 AR session + 3D rendering |
| `camera` | Tier 2 camera preview + scan shutter |
| `sensors_plus` | Tier 2 accelerometer (step detection) |
| `flutter_compass` | Tier 2 magnetometer heading |
| `opencv_dart` | Tier 2 visual localization (pinned `2.2.1+4`) |
| `path_provider` | Ground-truth log file path |
| `fuzzy` | Shop search bottom sheet |
| `permission_handler` | Runtime permissions (camera, location) |
| `vector_math` | 3D math (used by `ar_flutter_plugin_2` internally) |

`opencv_dart` modules enabled via `pubspec.yaml` `hooks.user_defines.dartcv4.include_modules`: `calib3d` (solvePnP, findHomography), `features2d` (ORB, BFMatcher), `imgproc` (color conversion, Laplacian), `imgcodecs` (JPEG decode). Other modules are excluded to keep the binary size down.

### Platform Notes

- Android: Tier 1 requires ARCore support; Tier 2/3 work on any device with sensors. Camera intrinsics come from `CameraCharacteristics.LENS_INTRINSIC_CALIBRATION` when available, else derived from focal length + sensor size.
- iOS: Tier 1 requires ARKit-capable device; compass needs `locationWhenInUse` permission or it returns -1. Camera intrinsics derived from `AVCaptureDevice.activeFormat.videoFieldOfView` (good to ~5%; for true intrinsics we'd need to own the AVCaptureSession).
- `permission_handler` and `geolocator` are both overridden in `pubspec.yaml` due to version conflicts — do not remove these overrides.
- macOS host (for `flutter test`): requires `cmake` (`brew install cmake`) so opencv_dart can build native artifacts.
