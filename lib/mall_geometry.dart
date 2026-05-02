import 'dart:math' as math;

import 'ar_navigation_system.dart';
import 'mall_data.dart' show Shop;

// ═══════════════════════════════════════════════════════════════
// mall_geometry — single source of truth for coordinate-frame math.
//
// All angle/coord conversions in the visual-localization stack route
// through this module. The conventions encoded here MUST match what
// shops.json declares in coordinateSystem (units=meters,
// angleConvention=ccw_from_positive_x_degrees, angleRange=[0, 360)).
//
// Conventions (documented for future readers — changing these is a
// repository-wide search-and-replace):
//   - Units: meters.
//   - Handedness: right-handed.
//   - Y-up: +Y is vertical (floor height).
//   - +X axis: building's longest axis (NOT compass north).
//   - +Z axis: horizontal, perpendicular to +X, completes right-handed
//     frame with +Y up.
//   - Angle zero: 0° = facing +X.
//   - Angle direction: counter-clockwise viewed from above (down −Y).
//   - Angle range: [0°, 360°), enforced by normalizeAngle.
//
// Compass alignment: the angle between mall +X and compass north is one
// constant — kMallNorthOffsetDeg below. Measure once at the mall (point
// the phone along +X, read the compass) and update.
// ═══════════════════════════════════════════════════════════════

const String kAngleZeroAxis = '+X';
const String kAngleRotation = 'CCW from above (looking down −Y)';

// TODO(field-measure): set this to the angle between mall +X and compass
// north, measured on-site. Until then, compass→mall conversions assume
// the building is compass-aligned, which it almost never is.
const double kMallNorthOffsetDeg = 80.0;

/// Wrap any angle in degrees to the half-open range [0, 360).
double normalizeAngle(double deg) => ((deg % 360.0) + 360.0) % 360.0;

/// Convert raw compass heading (clockwise from north, degrees) into the
/// mall's heading convention (CCW from +X, degrees, [0, 360)).
///
/// Math: compass measures CW from north, mall measures CCW from +X. The
/// 90 accounts for the axis swap (+X is east-ish in math vs north in compass);
/// the offset accounts for the mall's rotation relative to compass north.
double compassToMallHeading(
  double compassDeg, {
  double mallNorthOffset = kMallNorthOffsetDeg,
}) {
  return normalizeAngle(90.0 - compassDeg + mallNorthOffset);
}

/// Convert mall heading (degrees, CCW from +X) to radians.
double degToRad(double deg) => deg * math.pi / 180.0;

/// Convert radians to mall-heading degrees, normalized to [0, 360).
double radToDeg(double rad) => normalizeAngle(rad * 180.0 / math.pi);

/// Take a position expressed in the sign's local frame (origin at sign
/// center, +X along sign width, +Y up, +Z out of the sign face) and
/// transform it into the mall's global frame.
///
/// Steps:
///   1. Shift the sign-center origin down to the floor so Y becomes
///      height-above-floor (sign center sits at heightAboveDoor +
///      signHeight/2 above the doorstep floor).
///   2. Rotate around +Y by the shop's facingAngle so the sign's
///      out-of-face axis points into the corridor in mall coordinates.
///   3. Translate to the shop's doorstep.
Vector3 signFrameToMallFrame(Vector3 posInSign, Shop shop) {
  // 1. Shift sign-center → floor. The sign center is
  // heightAboveDoor + signHeight/2 above the doorstep floor, so a camera
  // at the sign-frame origin lands at that height in floor-referenced
  // mall Y. A camera held below the sign center (negative sign-frame Y)
  // therefore lands at a smaller floor height — exactly what we want.
  final signCenterAboveFloor =
      shop.sign.heightAboveDoorMeters + shop.sign.heightMeters / 2;
  final shifted = Vector3(
    posInSign.x,
    posInSign.y + signCenterAboveFloor,
    posInSign.z,
  );

  // 2. Rotate by facingAngle around +Y.
  // The shop's facingAngle is the direction the door points into the
  // corridor, in mall coords. Sign frame's +Z points out of the sign
  // face, so rotating sign +Z onto the mall direction at facingAngle
  // means rotating sign-frame vectors by (facingAngle - 90°): in sign
  // frame +Z is "out", which conventionally corresponds to a heading
  // of 90° in the standard CCW-from-+X angle convention.
  final theta = degToRad(shop.facingAngle - 90.0);
  final c = math.cos(theta);
  final s = math.sin(theta);
  final rotated = Vector3(
    shifted.x * c - shifted.z * s,
    shifted.y,
    shifted.x * s + shifted.z * c,
  );

  // 3. Translate to doorstep.
  return rotated + shop.doorstep;
}

/// Advance a position by one step of the given stride along the given
/// mall heading. Stride is in meters; heading is in mall-degrees.
Vector3 pdrStep(Vector3 cur, double mallHeadingDeg, double stride) {
  final rad = degToRad(mallHeadingDeg);
  final dx = stride * math.cos(rad);
  final dz = stride * math.sin(rad);
  return Vector3(cur.x + dx, cur.y, cur.z + dz);
}
