# Mall Navigation — Visual Localization Implementation Plan

## Phase 0: Foundations & Decisions

- [ ] **Lock coordinate system conventions.** This is the foundation every other task sits on. Inconsistency here causes bugs that look like "user appears on wrong side of corridor," "heading is 90° off," "position drifts after each update" — hours of debugging. Decide each of the following explicitly, document in `coordinate_system.md` with a labeled floor plan diagram, and encode in code as named constants.

  **Recommended defaults (use these unless you have a specific reason not to):**

  - **Units: meters.** Always SI. If floor plans are in feet, convert once at import.
  - **Handedness: right-handed.** Matches OpenCV / `solvePnP` output. Mismatched handedness causes mirrored positions across the corridor.
  - **Y-up:** +Y = vertical (floor height). You're already using this.
  - **+X axis:** along the building's longest axis (or main corridor direction) — *not* aligned to compass north. Buildings are rarely compass-aligned; aligning to geometry keeps coordinates clean and floor plans render naturally.
  - **+Z axis:** horizontal, perpendicular to +X, chosen so the system is right-handed (with +Y up, +Z points such that rotating +X 90° counter-clockwise viewed from above lands on +Z).
  - **Origin:** a permanent structural point, ideally a building corner so all coordinates are positive. Recommended: ground-floor corner at the "negative" end of both X and Z, so the building extends into the +X, +Z quadrant.
  - **Angle zero:** 0° = facing +X axis.
  - **Angle direction:** counter-clockwise when viewed from above (looking down −Y).
  - **Angle range:** `[0°, 360°)`, normalized via `((angle % 360) + 360) % 360` at every entry point.

  **Compass alignment (the only place compass touches your system):**

  - Measure once: the angle between mall +X and true (or magnetic — pick one) north. Store as a single constant `mallNorthOffset`.
  - Get this value from the floor plan's north arrow with a protractor, or by standing on your +X axis in the mall and reading the phone's compass.
  - All compass-to-mall conversions go through one function: `mallHeading = (90 - compassHeading + mallNorthOffset + 360) % 360`. The `90` accounts for compass (clockwise from north) vs math (counter-clockwise from +X) conventions.

  **Defensive coding habits to enforce:**

  - **Single `mall_geometry.dart` module.** All coordinate conversions live here: `compassToMallHeading()`, `signFrameToMallFrame()`, `pdrStep()`, `mallToScreenCoords()`. Every other file imports from this. Convention changes touch one file.
  - **Named constants, not magic literals.** Define `ANGLE_ZERO_AXIS`, `ANGLE_ROTATION_DIRECTION`, etc. as documented constants. Reference them in comments where math depends on the choice.
  - **Encode conventions in the data.** The `mall.coordinateSystem` block in your schema (already in Phase 0 schema task) carries this metadata so the app can validate at load time.

  **Validation pass before going further:**

  Before surveying a single shop, validate the system on 3 known points (e.g., main entrance, a specific shop door, an elevator):

  - Measure their (x, y, z) by hand from origin with a tape measure.
  - Plot on graph paper. Do they look right relative to each other vs the actual mall?
  - Pick two opposite-facing shops — their `facingAngle` values should differ by ~180°.
  - Pick a shop on the east side of a north-south corridor — its `facingAngle` should point west into the corridor.
  - Open the app's debug screen (next bullet), point camera at any sign with known coordinates, confirm computed user position matches your physical position within ~1 m.

  If anything feels off, you have a sign or handedness flip. Fix now — fixing after surveying 200 shops is painful.

- [ ] **Build a coordinate debug screen early.** A developer-only view that simultaneously displays: the floor plan with your current position pin, your heading direction as an arrow, the last solvePnP raw output, the compass raw reading and converted mall heading, and the most recent PDR step vector. Walk around the mall watching all five agree. Most convention bugs are obvious within 30 seconds of looking at this screen — much faster than reading logs.
- [ ] **Define the shop data schema.** Shops carry localization data (heavy); the navigation graph carries topology only (light). One shop can be referenced by multiple nav nodes (corner shops with two entrances). Canonical shape:

  ```json
  {
    "version": 1,
    "mall": {
      "id": "mall_001",
      "name": "Example Mall",
      "coordinateSystem": {
        "units": "meters",
        "angleConvention": "ccw_from_positive_x_degrees",
        "angleRange": "[0, 360)"
      }
    },
    "shops": [
      {
        "id": "window",
        "name": "Window",
        "doorstep": {"x": 3, "y": 0, "z": 0},
        "facingAngle": 90,
        "sign": {
          "widthMeters": 1.2,
          "heightMeters": 0.4,
          "heightAboveDoorMeters": 2.1
        },
        "featureFile": "features/window.bin",
        "featureCount": 95
      }
    ],
    "navigationGraph": {
      "nodes": [
        {"id": "door", "x": 0, "y": 0, "z": 0, "shopId": null},
        {"id": "n_window", "x": 3, "y": 0, "z": 0, "shopId": "window"}
      ],
      "edges": [
        {"from": "door", "to": "n_window", "weight": 3.0}
      ]
    }
  }
  ```

  - **`facing_angle` definition:** the direction the shop's door points outward into the corridor, in mall coordinates. Convention is documented in `mall.coordinateSystem.angleConvention` so the data is self-describing. This angle bridges the sign's local frame (from solvePnP) and the mall's global frame.
  - **`sign.heightAboveDoorMeters`:** vertical offset from doorstep to sign center. Required to shift solvePnP's reference from sign to doorstep.
  - **`featureFile`:** path (relative to assets root) to the bundled binary file with that shop's ORB descriptors. Lazy-loaded on shop selection.
  - **`featureCount`:** sanity check at load time — expected vs actual keypoint count catches corrupted files.
  - Write as typed Dart classes (with `fromJson` / `toJson`) for the app, and as a JSON schema for the data pipeline.
- [ ] **Future-proofing fields (add when relevant, not on day one):** `shop.aliases` for fuzzy search, `shop.category` for filtering, `floorId` string label per shop/node alongside the numeric `y`, `node.nodeType` (corridor/elevator/stairs/escalator/shopEntrance) for better turn-by-turn, `edge.bidirectional: false` for one-way paths like escalators.
- [ ] **Tech stack: Flutter.** Targeting Android + iOS from a single codebase using `opencv_dart` for computer vision.
  - Requires **Flutter ≥ 3.38 / Dart ≥ 3.10** (needed for the Native Assets / hooks system used by `opencv_dart` v2.x).
  - On older Flutter, fall back to `opencv_dart` v1.4.5.
  - Pin the version in `pubspec.yaml` rather than using a loose constraint — the package is still labeled WIP and APIs may shift.
- [ ] **Lock angle normalization rule.** All angles (facing_angle, compass headings, computed bearings) stored and passed in the half-open range `[0°, 360°)`. Apply `((angle % 360) + 360) % 360` at every entry point and after every angle arithmetic operation. Validate in the surveyor tool: two shops directly across a corridor should have facing_angles differing by ~180°.
- [ ] **Set accuracy targets.** E.g., ≤1 m position error at 2–5 m viewing distance, ≤10° heading error. Measurable goals prevent scope creep.

## Phase 1: Offline Data Pipeline (Desktop Tool)

- [ ] **Build a shop surveyor tool.** Python CLI or Dart desktop app (the latter lets you reuse `opencv_dart` — same package supports Linux/macOS/Windows, so feature extraction logic can be shared with the mobile app). Given a reference photo of a sign, (a) lets you click the 4 corners of the sign, (b) records real-world sign width/height via manual input, (c) extracts ORB features constrained to the sign region.
- [ ] **Implement feature extraction.** Use OpenCV ORB with tuned parameters (nfeatures=500, then keep top 80–100 by response score). Output binary descriptors + keypoint coordinates normalized to sign dimensions.
- [ ] **Design the on-disk feature format.** Compact binary: header (shop_id, keypoint count, sign dimensions) + keypoint array + descriptor blob. Target <5 KB per shop.
- [ ] **Survey workflow for the mall.** Process to physically capture each shop: standard distance (~3 m), straight-on angle, good lighting, measure sign dimensions and height-above-door with a tape measure. Document this so a non-technical person can do it.
- [ ] **Build the shop database generator.** Script that takes all surveyed shops + mall map coordinates and outputs the bundled asset file(s) shipped with the app.
- [ ] **Validation harness.** Take extra photos per shop from varied angles/distances. Run the matching pipeline offline and confirm pose estimation gives correct coordinates before shipping that shop's data.

## Phase 2: Core On-Device Modules (Flutter)

- [ ] **Add `opencv_dart` to the project.** In `pubspec.yaml`, add `opencv_dart: ^2.2.1+4` (or pinned newer) and configure required modules — both `calib3d` and `features2d` are **excluded by default** and must be explicitly enabled, or runtime calls will throw "symbol not found":
  ```yaml
  hooks:
    user_defines:
      dartcv4:
        include_modules:
          - calib3d      # solvePnP, findHomography
          - features2d   # ORB, BFMatcher
          - imgproc      # color conversion, image ops
          - imgcodecs    # image I/O
  ```
  Set `DARTCV_CACHE_DIR` env var on dev machines and CI to cache the ~100 MB OpenCV SDK download.
- [ ] **Build a smoke-test screen.** Bundle one test image as an asset, run the full pipeline (ORB → BFMatcher → findHomography → solvePnP) on it, log results. Confirms the package, modules, and platform binaries all work on both Android and iOS before going further.
- [ ] **Wrap OpenCV in an abstraction layer.** Create a `LocalizationService` Dart class that exposes high-level methods (`extractFeatures(image)`, `matchAndLocalize(frame, shopFeatures, shopData)`) and hides all `opencv_dart` calls behind it. If the package needs to be swapped later (platform channels + native OpenCV), only this file changes.
- [ ] **Camera capture (scan-on-tap).** Use the official `camera` plugin. Show a live preview (no processing — just the platform's native preview widget) with an overlay reticle indicating where to frame the sign. User taps a shutter button → call `takePicture()` to capture a single high-resolution frame → pass to the localization isolate. No frame streaming, no per-frame conversion, no throttling. Saves battery, avoids thermal issues, gives better per-scan accuracy because users naturally hold the phone steady when taking a shot.
- [ ] **Camera intrinsics platform channel.** The `camera` plugin doesn't expose focal length or principal point. Write a small platform channel: CameraX's `CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS` + sensor size on Android, `AVCaptureDevice` intrinsics matrix on iOS. Test on at least 3 different phone models — values vary by device and hardcoding will wreck solvePnP accuracy.
- [ ] **Isolate-based processing.** Run the OpenCV pipeline (ORB → BFMatcher → findHomography → solvePnP) in a background isolate via `compute()`. Single captured frame in, pose estimate out. Keeps the UI thread responsive during the ~200–500 ms processing time; show a loading indicator while it runs.
- [ ] **Sensor module.** Use `flutter_compass` for fused heading (or `sensors_plus` if more control needed). Use `pedometer` for cumulative step count (derive deltas yourself). Wrap both in a `SensorService` Dart class exposing current heading + step delta stream.
- [ ] **Asset loader.** Bundle the shop database in `assets/` declared in `pubspec.yaml`. Load lightweight metadata at app start via `rootBundle.load()`. On shop selection, lazy-load that shop's ~5 KB feature file from assets.
- [ ] **Shop search UI.** Searchable list with fuzzy matching (the `fuzzy` package or similar). Selecting a shop sets the "current target" in the localization service.

## Phase 3: Localization Engine

- [ ] **Feature matching on camera frame.** Extract ORB features from live frame, match against loaded shop's descriptors using BFMatcher with Hamming distance and Lowe's ratio test. Aim for ≥15 good matches as a confidence threshold.
- [ ] **Homography estimation.** RANSAC-based homography from matched points. Reject if inliers <10 or reprojection error too high.
- [ ] **Sign corner recovery.** Apply homography to the known rectangular sign corners to get their pixel locations in the live frame.
- [ ] **Pose estimation via solvePnP.** Input: 4 sign corners in image + 4 corresponding 3D points (sign rectangle in its local frame, centered at origin). Output: rotation and translation of the camera relative to the sign.
- [ ] **Coordinate transform.** Apply sign-height offset to shift reference from sign center to doorstep. Rotate into mall coordinates using shop's facing angle. Add doorstep position. Output: user (x, z) with y = shop's floor.
- [ ] **Sanity checks.** Reject results where: camera appears below floor or above ceiling, distance is absurd (<0.5 m or >30 m), inlier count is low, or homography is degenerate. Surface clear error to user ("Move closer," "Try better lighting").
- [ ] **Single-frame quality gating.** Since scan-on-tap captures one frame, quality matters per-shot. Reject blurry frames (Laplacian variance below threshold) before processing, and reject low-confidence pose results. On rejection, prompt user to retake rather than averaging across frames.

## Phase 4: Between-Scan Tracking

- [ ] **Pedestrian dead reckoning.** On step detection events, advance user position in the current heading direction by an average stride length (default 0.7 m, optionally per-user calibrated).
- [ ] **Heading source.** Use the OS-fused rotation vector, not raw magnetometer. Expose both the user's facing direction and a confidence estimate.
- [ ] **Drift handling.** Track accumulated steps since last visual fix. After N steps (e.g., 20) or T seconds (e.g., 30), visually de-emphasize the position on the UI and prompt user to rescan.
- [ ] **Re-localization trigger.** Easy, one-tap way for the user to point at any shop and re-anchor. Treat every successful visual fix as ground truth that resets drift.

## Phase 5: Integration with Navigation

- [ ] **Pathfinding module.** A\* or Dijkstra on your existing navigation graph. Input: current (x, y, z), destination shop_id. Output: sequence of waypoints including floor transitions (stairs/elevators/escalators).
- [ ] **Turn-by-turn UI.** Render user position and route on the mall map. Update on every position fix and PDR step.
- [ ] **Floor changes.** When route crosses floors, instruct user to take specific stairs/elevator and rescan at destination floor to confirm new position.

## Phase 6: Testing & Calibration

- [ ] **Ground truth collection.** In a pilot area (5–10 shops), physically measure known positions with tape from shop doorsteps. Stand at each position, scan, log predicted vs actual coordinates.
- [ ] **Accuracy metrics.** Mean position error, 95th percentile error, heading error, failure rate (scans producing no valid fix). Track against Phase 0 targets.
- [ ] **Stress tests.** Poor lighting, crowded scenes (sign partially occluded), glass reflections, extreme angles, phone tilted up/down.
- [ ] **Per-shop reliability audit.** Some signs will match poorly. Identify them, re-survey with better reference photos or fiducial marker fallback, re-ship.
- [ ] **Battery and thermal profiling.** Ensure continuous camera + feature matching doesn't drain battery or overheat. Consider scan-on-demand rather than continuous.

## Phase 7: Rollout & Maintenance

- [ ] **Pilot in one section of the mall.** 10–20 shops. Real user testing.
- [ ] **Expand to full mall.** Survey remaining shops using the Phase 1 tool.
- [ ] **Update pipeline.** Process for adding new shops: survey → regenerate database → ship app update. Consider optional online delta updates for tenants who change between releases.
- [ ] **Analytics (optional, offline-friendly).** Log failed scans locally and batch-upload with user consent to identify problem shops.
- [ ] **Fallback modes.** Manual "I'm near shop X" selection if visual scanning fails repeatedly, so navigation always works.

## Risks & Mitigations (keep this list living)

- **Compass errors indoors.** Mitigate by deriving heading from solvePnP when visual fix is available; trust vision over magnetometer on disagreement.
- **Similar-looking signs confusing feature matching.** User pre-selection eliminates cross-shop confusion but not wrong-sign-on-same-storefront. Aspect ratio check on recovered corners catches most cases.
- **Signs that change seasonally (holiday decor, sales banners).** Document in survey process; re-survey shops that frequently redecorate their signage.
- **Dark or reflective signs.** Identify during Phase 6, add fiducial markers to problem shops as a last resort.
- **`opencv_dart` is still WIP.** Package is actively maintained but the README warns APIs may shift. Pin the version, abstract OpenCV calls behind a service class, and keep an eye on the changelog for breaking changes before upgrading.
