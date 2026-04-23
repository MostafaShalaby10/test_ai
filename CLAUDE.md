# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run the app (requires device/emulator)
flutter analyze          # Static analysis (flutter_lints)
flutter test             # Run tests
flutter test test/widget_test.dart  # Run a single test file
flutter build apk        # Build Android APK
flutter build ios        # Build iOS (requires Mac + Xcode)
```

## Architecture

Flutter AR indoor navigation app for malls/buildings. The app auto-detects device hardware and falls into one of three tiers:

| Tier | Requirement | Screen | How it works |
|---|---|---|---|
| **1 — Full AR** | ARCore/ARKit | `ar_navigation_screen.dart` | `ar_flutter_plugin_2` renders 3D scene; `CoordinateAligner` maps AR world coords ↔ map coords |
| **2 — Sensor AR** | Gyroscope + magnetometer (no ARCore) | `sensor_ar_screen.dart` | Camera feed + compass arrow overlay; PDR (step detection + compass heading) tracks position; MindAR image-tracking via WebView corrects drift |
| **3 — 2D Map** | Anything else | `map_2d_screen.dart` | Static 2D graph rendering with turn-by-turn directions |

Tier detection happens in `device_capability_checker.dart` → `NavigationTier` enum. `main.dart` routes to the right screen; Tier 2 is deferred-loaded to avoid pulling `webview_flutter` into Tier 1/3 builds.

### Core Navigation System (`lib/ar_navigation_system.dart`)

Shared by all three tiers. Contains:

- **`Vector3`** — Lightweight 3D vector math (custom, not the `vector_math` package type)
- **`NavGraph`** — Graph of waypoints with weighted/directed edges; A\* pathfinding with a custom min-heap
- **`CoordinateAligner`** — Yaw-aware transform between AR world coordinates and map coordinates. Misalignment here breaks all Tier 1 navigation — this is the trickiest part of the system.
- **`QRAnchorRegistry`** — Maps QR code values → known map positions for alignment
- **`AvatarGuide`** — Walks a 3D avatar along waypoints; advances when user is within `arrivalThreshold`
- **`NavigationSession`** — Ties graph + aligner + guide + QR registry into one session object

### PDR Tracker (`lib/pdr_tracker.dart`)

Pedestrian Dead Reckoning — the position engine for Tier 2 (no ARCore). Key design decisions:

- **Step detection state machine**: idle → rising → falling → valley → count. Uses smoothed accelerometer magnitude from `sensors_plus` `userAccelerometerEventStream` (gravity-free).
- **Walking lock**: requires `minConsecutiveSteps` (default 2) valid steps before counting position moves, preventing jitter from non-walking motion.
- **Compass smoothing**: circular mean over a rolling window; gates on `accuracy` to reject noisy indoor readings. Waits for `_headingMinSamplesForInit` samples before latching initial heading.
- **Direction**: only forward vs. lateral (half-step). Backward detection was removed — body-frame accelerometer sign is unreliable.
- **Corrections**: `snapToNodes()` snaps position to nearby waypoints; `correctPosition()` is called when MindAR detects a known image marker.

### MindAR Integration (`lib/mindar_detector.dart` + `assets/mindar_tracker.html`)

Image tracking runs in a WebView loading `mindar_tracker.html`. When a known image target is detected, it posts a JS message to `MarkerChannel` → the Flutter side looks up the marker in `ImageMarkerRegistry` and calls `PDRTracker.correctPosition()`. This is how Tier 2 fights PDR drift.

### Navigation Data

The graph (nodes + edges) is currently **hardcoded in `main.dart`** (`_mallData` map literal), not loaded from an asset file. Image marker definitions are also inline in `main.dart` (`_imageMarkers`).

### State Management

No state management library. All state lives in `StatefulWidget`s with `setState()`.

### Key Dependencies

| Package | Purpose |
|---|---|
| `ar_flutter_plugin_2` | Tier 1 AR session + 3D rendering |
| `camera` | Tier 2 raw camera feed |
| `sensors_plus` | Tier 2 accelerometer (step detection) |
| `flutter_compass` | Tier 2 magnetometer heading |
| `webview_flutter` | Tier 2 MindAR image tracking host |
| `permission_handler` | Runtime permissions (camera, location) |
| `vector_math` | 3D math (used by `ar_flutter_plugin_2` internally) |

### Platform Notes

- Android: Tier 1 requires ARCore support; Tier 2/3 work on any device with sensors
- iOS: Tier 1 requires ARKit-capable device; compass needs `locationWhenInUse` permission or it returns -1
- `permission_handler` and `geolocator` are both overridden in `pubspec.yaml` due to version conflicts — do not remove these overrides
