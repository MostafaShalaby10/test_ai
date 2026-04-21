# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run the app (requires device/emulator)
flutter analyze          # Static analysis (flutter_lints/flutter.yaml)
flutter test             # Run tests
flutter build apk        # Build Android APK
flutter build ios        # Build iOS (requires Mac + Xcode)
flutter test test/widget_test.dart  # Run a single test file
```

## Architecture

This is a Flutter AR indoor navigation app for malls/buildings. It supports two operational modes:
1. **Initial-position mode** — user specifies their starting location manually
2. **QR-code mode** — user scans a QR code to align AR coordinate systems with the physical space

### Core Navigation System (`lib/ar_navigation_system.dart`)

This is the backbone of the app (~900 lines). It contains all the logic that the UI files depend on:

- **`Vector3`** — Lightweight 3D vector math used throughout
- **`NavGraph`** — Graph of waypoints with edges; contains the A\* pathfinding implementation
- **`CoordinateAligner`** — Transforms between AR world coordinates (ARCore/ARKit output) and mall map coordinates (the static node graph). This is the trickiest part of the system — misalignment here breaks all navigation.
- **`AvatarGuide`** — Manages the 3D avatar's position along waypoints; determines when to advance to the next waypoint based on proximity
- **`NavigationSession`** — Ties it all together: holds graph, aligner, guide, and current session state

### UI Files

- **`lib/ar_navigation_screen.dart`** — Initial-position mode. Uses `ar_flutter_plugin_2` for AR rendering, places the 3D avatar GLB model (`assets/avatar.glb`) at computed waypoints
- **`lib/ar_navigation_flow.dart`** — QR-code alignment flow. Uses `mobile_scanner` for QR reading, then transitions into the full AR navigation view
- **`lib/avatar_screen.dart`** — Fallback UI using `camera` + `flutter_compass` for devices without full ARCore/ARKit support; renders avatar as a 2D overlay
- **`lib/main.dart`** — Entry point; home screen that routes to the appropriate flow
- **`lib/store_model.dart`** — Data models: `Store` (destination metadata) and `MapData` (the node/edge graph loaded from `assets/map.json`)

### State Management

No state management library is used. All state lives in `StatefulWidget`s with `setState()`. There is no BLoC, Riverpod, Provider, or GetX.

### Key Dependencies

| Package | Purpose |
|---|---|
| `ar_flutter_plugin_2` | AR session + 3D node rendering (cross-platform) |
| `arkit_plugin` | iOS ARKit direct integration |
| `model_viewer_plus` | 3D GLB/GLTF model viewer |
| `mobile_scanner` | QR code scanning |
| `flutter_compass` | Device heading/orientation |
| `permission_handler` | Runtime permissions (camera, location) |
| `vector_math` | 3D math (also used internally via the custom `Vector3`) |

### Assets

- `assets/avatar.glb` — 3D avatar model rendered in AR
- `assets/avatar.png` — 2D fallback avatar image
- `assets/map.json` — Navigation graph (nodes + edges for A\* pathfinding)

### Platform Notes

- iOS: requires ARKit-capable device; `ios/Podfile` and `macos/Podfile` are present but not committed
- Android: requires ARCore support
- `permission_handler` is overridden to `^11.0.0` in `pubspec.yaml` due to a version conflict — do not remove this override
