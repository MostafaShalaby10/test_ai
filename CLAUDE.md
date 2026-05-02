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
| **1 — Full AR** | ARCore/ARKit | `ar_navigation_screen.dart` | `ar_flutter_plugin_2` runs SLAM continuously; alignment is bootstrapped by the **same scan-on-tap visual fix as Tier 2** (uses `IsolateLocalizer` + true ARKit intrinsics from `mall_nav/ar_intrinsics`); `CoordinateAligner` then maps AR world ↔ mall coords every frame |
| **2 — Sensor AR** | Gyroscope + magnetometer (no ARCore) | `sensor_ar_screen.dart` | Camera feed + PDR + scan-on-tap **visual localization** (ORB → solvePnP via `opencv_dart`) corrects drift |
| **3 — 2D Map** | Anything else | `map_2d_screen.dart` | Static 2D graph rendering with turn-by-turn directions |

Tier detection happens in `device_capability_checker.dart` → `NavigationTier` enum. `main.dart` routes to the right screen; Tier 2 is deferred-loaded to keep the camera/isolate setup code out of the eager bundle (`opencv_dart` itself is unconditional and shared with Tier 1's visual fix).

### Mall data pipeline

The graph (nodes + edges) and shop metadata live in `assets/mall/shops.json`, produced by the sibling [`/Users/m.ead/apps/sign_surveyor`](../sign_surveyor) Python tool. Per-shop ORB feature files live in `assets/mall/features/<shop_id>.bin` (SSF1 binary format, ~5 KB each).

To add or update shops:
1. Run the surveyor on the new sign(s)
2. `bash scripts/sync_mall_assets.sh` (copies `shops.json` + `output/*.bin` here)
3. `flutter pub get` and rebuild

The schema declares `coordinateSystem: {units: meters, angleConvention: ccw_from_positive_x_degrees, angleRange: "[0, 360)"}` — `MallData.fromJson` enforces this at load time.

**Map-only destinations**: graph nodes whose `shopId` has no matching real shop (e.g. a `window` node with no surveyed sign) are surfaced as destinations by synthesising a `featureFile`-less `Shop` for them in `MallData.fromJson`. They appear in the destination picker but stay out of the scannable starting-shop picker (which filters on `featureFile != null`).

### Core Navigation System (`lib/ar_navigation_system.dart`)

Shared by all three tiers. Contains:

- **`Vector3`** — Lightweight 3D vector math (custom; no `==` override). Has both `distanceTo` (3D) and `distanceToXZ` (floor-plane). **Use `distanceToXZ` for any user↔node comparison** (arrival, snap, nearest-node) since the user's mall y reflects camera-floor height (~1.5 m) while graph nodes sit at y=0; 3D distance always overestimates by ~1.5 m and makes thresholds unreachable. Node↔node distances stay 3D for multi-floor support.
- **`NavGraph`** — A* pathfinding over weighted/directed waypoints; min-heap implementation. `findNearestNode` uses xz.
- **`CoordinateAligner`** — Yaw-aware AR world ↔ map transform. Misalignment here breaks all Tier 1 navigation — trickiest part of the system.
- **`QRAnchorRegistry`** — Map QR code values → known map positions for Tier 1 alignment.
- **`AvatarGuide`** + **`NavigationSession`** — Walks an avatar along waypoints; ties graph + aligner + guide together. Arrival check uses `distanceToXZ`.

### Visual Localization Stack (Tier 2)

Replaces the previous MindAR/WebView image tracker. Scan-on-tap: user picks a target shop, points the camera at its sign, taps the shutter, and the pipeline returns a fresh mall-frame position fix. PDR fills in between scans.

- **`lib/mall_data.dart`** — Typed schema mirroring `shops.json`. `MallData.loadFromAssets()` + lazy `loadFeaturesForShop()`. Synthesises destination-only Shops for graph-only nodes (see "Map-only destinations" above).
- **`lib/feature_format.dart`** — Pure-Dart SSF1 binary reader (host-VM testable; no opencv_dart dependency).
- **`lib/mall_geometry.dart`** — **Single source of truth** for coordinate-frame math. `normalizeAngle`, `compassToMallHeading`, `signFrameToMallFrame`, `pdrStep`, `degToRad`, `radToDeg`. **Every coordinate convention change goes through this file.** Defines `kMallNorthOffsetDeg` (TODO: must be measured at the actual mall). **Mall y is floor-referenced**: `signFrameToMallFrame` shifts the sign-frame origin down to the floor by `heightAboveDoor + signHeight/2`, so a camera held at chest height in front of a sign lands at mall y ≈ 1.5 m (not below floor as in the original convention).
- **`lib/camera_intrinsics.dart`** + native channels:
  - `mall_nav/camera_intrinsics` (Android Kotlin in `MainActivity.kt`, iOS Swift in `AppDelegate.swift`) — fetches per-device fx/fy/cx/cy for the back camera. Falls back to FOV-estimated intrinsics if native fails. Used by Tier 2 (the `camera` plugin's preview frames are at the back-camera resolution).
  - `mall_nav/ar_intrinsics` (`ARIntrinsicsChannel`) — derives pinhole intrinsics from the AR session's projection matrix at the active view dimensions, in **snapshot pixel space**. iOS reads `ARSession.currentFrame.camera.projectionMatrix(for:viewportSize:zNear:zFar:)` after walking `UIWindowScene` for an `ARSCNView`. Android walks `Activity.window.decorView` for an `ARSceneView` (sceneview lib, brought in by `ar_flutter_plugin_2`) then pulls `currentFrame → frame → camera.getProjectionMatrix(...)` via reflection — reflection avoids a compile-time sceneview dependency in our app. Captures FOV, aspect cropping, and device orientation correctly. Used by Tier 1's scan-on-tap. **Required for Tier 1 accuracy** — the FOV-estimated fallback was 5–10° off, which biased solvePnP into sign-flipped poses and 30–50° heading errors.
- **`lib/localization_service.dart`** — Wraps every `opencv_dart` call: ORB (params **identical** to surveyor: `nFeatures=500, scaleFactor=1.2, nLevels=8, edgeThreshold=15`, top-100 by response) → BFMatcher (NORM_HAMMING, Lowe ratio 0.75) → findHomography (RANSAC, 3px) → perspectiveTransform → solvePnP (SOLVEPNP_IPPE_SQUARE on the 4 sign corners) → sign frame → mall frame via `signFrameToMallFrame`. Sanity gates on Laplacian variance (blur), distance, and y-height. Match/inlier gates: `_minGoodMatches=10`, `_minInliers=7` (lowered from 15/10 to accommodate small reference feature sets, e.g. shops with `featureCount ≈ 80`). **Camera-forward in sign frame** is `+r[2]` (positive — third row of the rotation matrix, since OpenCV camera-forward is `+Z`); negating these (the original bug) makes every recovered heading 180° wrong, so the "Go straight" hint sends the user to walk toward the sign they're already facing.
- **`lib/isolate_localizer.dart`** — Long-lived isolate holding a singleton `LocalizationService`. ORB and BFMatcher are stateful native objects; recreating per scan would cost 50–150 ms — the isolate keeps them warm. JPEG bytes ride a `TransferableTypedData` for zero-copy. Shared between Tier 1 and Tier 2.
- **`lib/debug_screen.dart`** — Developer-only screen, reachable via long-press on the home title (debug builds only). Live displays of compass raw vs mall heading, PDR position + last step delta, last solvePnP output, last frame Laplacian variance. Buttons: "Run self-test" (uses bundled images at `assets/mall/test_images/<shop_id>.jpg`) and "Log fix → ground truth" (appends JSONL to `getApplicationDocumentsDirectory()`).

### Tier 1 specifics (`lib/ar_navigation_screen.dart`)

ARKit/ARCore handles continuous SLAM tracking; the visual fix is only used at the bootstrap moment to align the AR world to the mall world.

- **Phases**: `pickingDestination → pickingStartingShop → scanning → navigating → arrived`. The `scanning` phase shows a shutter button; tapping it captures `arSessionManager.snapshot()` (PNG of the rendered SCNView), runs the same ORB→solvePnP pipeline as Tier 2, then calls `_alignFromVisualFix(pose, mallPos, mallHeading)`. On failure the user stays in `scanning` and can retry — same human messages as Tier 2.
- **Heading source**: when `ARIntrinsicsChannel` succeeds, trust the visual heading from solvePnP. Only fall back to the `facingAngle + 180°` assumption if intrinsics had to be FOV-estimated (in which case visual heading can be wildly wrong).
- **Per-frame arrow math**: do **not** use `pose.getColumn(0)` for "user right" — ARKit's camera-local +X is the device-sensor long edge, which in portrait orientation points roughly toward world +Y (vertical), not user-right. Instead derive right from the xz-plane forward direction: `right = forward × up = (-fwd.z, _, fwd.x)`. Both forward and right must be **normalised** before computing `forwardComp`/`rightComp`, otherwise a pitched phone (looking at the floor while walking) shrinks the forward component by `cos(pitch)` and biases the bearing toward ±90°.
- **Telemetry**: the `[AR.NAV]` log lines (throttled to ~1 Hz) and the on-screen green debug overlay show `arPos`, `mapPos`, `avatarAR`, `d=(dX, dZ)`, `fwd`/`right`, `fwdYaw`, `tgtBrg`, and `smooth`. Essential for diagnosing "the arrow is wrong" complaints.

### PDR Tracker (`lib/pdr_tracker.dart`)

Pedestrian Dead Reckoning — the position engine for Tier 2 between scans. Key design decisions:

- **Step detection state machine**: idle → rising → falling → valley → count. Smoothed accelerometer magnitude from `sensors_plus` `userAccelerometerEventStream` (gravity-free).
- **Walking lock**: requires `minConsecutiveSteps` (default 2) valid steps before counting position moves, preventing jitter from non-walking motion.
- **Compass smoothing**: circular mean over a rolling window; gates on `accuracy` to reject noisy indoor readings. Waits for `_headingMinSamplesForInit` samples before latching initial heading.
- **Direction**: only forward vs. lateral (half-step). Backward detection was removed — body-frame accelerometer sign is unreliable.
- **Step math**: `_computeNewPosition` calls `mall_geometry.pdrStep` so the displacement convention lives in one file. Compass→mall normalization uses `mall_geometry.normalizeAngle`.
- **Corrections**:
  - `correctPosition(Vector3)` — manual fix (called from arrival anchoring and the start-shop manual fallback).
  - `correctPositionAndHeading(Vector3, double mallHeadingDeg)` — visual fix; treats vision as ground truth on disagreement (re-anchors `_initialHeading` so the current compass reading maps to the supplied mall heading). **If the compass hasn't latched yet** (which is the common case immediately after a scan), the heading is buffered into `_pendingMallHeadingDeg` and applied at latch time inside `_onCompassData`. Without this buffering the visual heading was silently dropped, leaving the user's mall-frame orientation anchored to whatever direction the compass first latched on — i.e. the arrow would say "Go straight" while pointing them at the wrong shop.
  - `snapToNodes(List<NavNode>)` — snaps to a candidate list (typically the path ahead). Distance comparison is xz-only (`distanceToXZ`).
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

- Android: Tier 1 requires ARCore support; Tier 2/3 work on any device with sensors. Tier 2 camera intrinsics come from `CameraCharacteristics.LENS_INTRINSIC_CALIBRATION` when available, else derived from focal length + sensor size. Tier 1 snapshot intrinsics derived from ARCore's `Camera.getProjectionMatrix` via reflection on sceneview's `ARSceneView` (`mall_nav/ar_intrinsics`).
- iOS: Tier 1 requires ARKit-capable device; compass needs `locationWhenInUse` permission or it returns -1. Tier 2 camera intrinsics derived from `AVCaptureDevice.activeFormat.videoFieldOfView` (good to ~5%). Tier 1 snapshot intrinsics derived from `ARSession.currentFrame.camera.projectionMatrix` (true FOV, orientation-aware) via `mall_nav/ar_intrinsics`.
- `permission_handler` and `geolocator` are both overridden in `pubspec.yaml` due to version conflicts — do not remove these overrides.
- macOS host (for `flutter test`): requires `cmake` (`brew install cmake`) so opencv_dart can build native artifacts.
