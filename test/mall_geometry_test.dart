import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:test_sensors/mall_geometry.dart';
import 'package:test_sensors/mall_data.dart' show Shop, SignDims;
import 'package:test_sensors/ar_navigation_system.dart' show Vector3;

void main() {
  // ── normalizeAngle ──────────────────────────────────────────────
  group('normalizeAngle', () {
    test('identity for values already in [0, 360)', () {
      expect(normalizeAngle(0.0), closeTo(0.0, 1e-9));
      expect(normalizeAngle(90.0), closeTo(90.0, 1e-9));
      expect(normalizeAngle(180.0), closeTo(180.0, 1e-9));
      expect(normalizeAngle(359.9), closeTo(359.9, 1e-9));
    });

    test('360 wraps to 0', () {
      expect(normalizeAngle(360.0), closeTo(0.0, 1e-9));
    });

    test('values above 360 wrap correctly', () {
      expect(normalizeAngle(450.0), closeTo(90.0, 1e-9));
      expect(normalizeAngle(720.0), closeTo(0.0, 1e-9));
      expect(normalizeAngle(361.0), closeTo(1.0, 1e-9));
    });

    test('negative values wrap to positive', () {
      expect(normalizeAngle(-90.0), closeTo(270.0, 1e-9));
      expect(normalizeAngle(-180.0), closeTo(180.0, 1e-9));
      expect(normalizeAngle(-0.1), closeTo(359.9, 1e-9));
      expect(normalizeAngle(-360.0), closeTo(0.0, 1e-9));
    });
  });

  // ── compassToMallHeading ────────────────────────────────────────
  group('compassToMallHeading', () {
    // With offset=0 the mall +X aligns with compass east.
    // Formula: normalizeAngle(90 - compassDeg + offset)
    group('with zero offset', () {
      test('north (0°) → mall 90°', () {
        expect(compassToMallHeading(0.0, mallNorthOffset: 0.0), closeTo(90.0, 1e-9));
      });

      test('east (90°) → mall 0°', () {
        expect(compassToMallHeading(90.0, mallNorthOffset: 0.0), closeTo(0.0, 1e-9));
      });

      test('south (180°) → mall 270°', () {
        expect(compassToMallHeading(180.0, mallNorthOffset: 0.0), closeTo(270.0, 1e-9));
      });

      test('west (270°) → mall 180°', () {
        expect(compassToMallHeading(270.0, mallNorthOffset: 0.0), closeTo(180.0, 1e-9));
      });
    });

    group('with kMallNorthOffsetDeg (80°)', () {
      test('north (0°) → mall 170°', () {
        expect(compassToMallHeading(0.0), closeTo(170.0, 1e-9));
      });

      test('east (90°) → mall 80°', () {
        expect(compassToMallHeading(90.0), closeTo(80.0, 1e-9));
      });

      test('result is always in [0, 360)', () {
        for (final c in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0, 359.0]) {
          final result = compassToMallHeading(c);
          expect(result, greaterThanOrEqualTo(0.0));
          expect(result, lessThan(360.0));
        }
      });
    });
  });

  // ── degToRad / radToDeg ─────────────────────────────────────────
  group('degToRad and radToDeg', () {
    test('known values', () {
      expect(degToRad(0.0), closeTo(0.0, 1e-9));
      expect(degToRad(90.0), closeTo(math.pi / 2, 1e-9));
      expect(degToRad(180.0), closeTo(math.pi, 1e-9));
      expect(degToRad(360.0), closeTo(2 * math.pi, 1e-9));
    });

    test('round-trip through radToDeg is identity (mod 360)', () {
      for (final deg in [0.0, 45.0, 90.0, 180.0, 270.0, 359.0]) {
        expect(radToDeg(degToRad(deg)), closeTo(deg, 1e-9));
      }
    });

    test('radToDeg normalizes result to [0, 360)', () {
      // -π/2 rad → -90° → normalized to 270°
      expect(radToDeg(-math.pi / 2), closeTo(270.0, 1e-9));
    });
  });

  // ── pdrStep ────────────────────────────────────────────────────
  group('pdrStep', () {
    const origin = Vector3(0, 0, 0);
    const stride = 1.0;

    test('heading 0° advances along +X', () {
      final result = pdrStep(origin, 0.0, stride);
      expect(result.x, closeTo(1.0, 1e-9));
      expect(result.y, closeTo(0.0, 1e-9));
      expect(result.z, closeTo(0.0, 1e-9));
    });

    test('heading 90° (CCW) advances along +Z', () {
      final result = pdrStep(origin, 90.0, stride);
      expect(result.x, closeTo(0.0, 1e-9));
      expect(result.y, closeTo(0.0, 1e-9));
      expect(result.z, closeTo(1.0, 1e-9));
    });

    test('heading 180° advances along −X', () {
      final result = pdrStep(origin, 180.0, stride);
      expect(result.x, closeTo(-1.0, 1e-9));
      expect(result.y, closeTo(0.0, 1e-9));
      expect(result.z, closeTo(0.0, 1e-9));
    });

    test('heading 270° advances along −Z', () {
      final result = pdrStep(origin, 270.0, stride);
      expect(result.x, closeTo(0.0, 1e-9));
      expect(result.y, closeTo(0.0, 1e-9));
      expect(result.z, closeTo(-1.0, 1e-9));
    });

    test('Y coordinate is unchanged', () {
      const start = Vector3(1.0, 5.0, 2.0);
      final result = pdrStep(start, 45.0, stride);
      expect(result.y, closeTo(5.0, 1e-9));
    });

    test('stride scales displacement', () {
      final result = pdrStep(origin, 0.0, 2.5);
      expect(result.x, closeTo(2.5, 1e-9));
    });

    test('accumulates from non-origin start', () {
      const start = Vector3(3.0, 0.0, 4.0);
      final result = pdrStep(start, 0.0, 1.0);
      expect(result.x, closeTo(4.0, 1e-9));
      expect(result.z, closeTo(4.0, 1e-9));
    });
  });

  // ── signFrameToMallFrame ────────────────────────────────────────
  group('signFrameToMallFrame', () {
    // Shop facing 90° (into the +Z corridor), doorstep at (5, 0, 0),
    // sign 2.0m above the doorstep.
    const shop90 = Shop(
      id: 'test',
      name: 'Test',
      doorstep: Vector3(5.0, 0.0, 0.0),
      facingAngle: 90.0,
      sign: SignDims(
        widthMeters: 1.0,
        heightMeters: 0.5,
        heightAboveDoorMeters: 2.0,
      ),
    );

    // Sign center sits at heightAboveDoor + signHeight/2 = 2.0 + 0.25 = 2.25
    // above the doorstep floor, so a camera at the sign-frame origin lands at
    // mall Y = 2.25.
    const signCenterAboveFloor = 2.25;

    test('user at sign-frame origin lands at sign-center height', () {
      // (0,0,0) → shift +signCenterAboveFloor: (0, 2.25, 0)
      // → rotate by (90−90)=0°: (0, 2.25, 0) → translate (5,0,0): (5, 2.25, 0)
      final result = signFrameToMallFrame(const Vector3(0, 0, 0), shop90);
      expect(result.x, closeTo(5.0, 1e-9));
      expect(result.y, closeTo(signCenterAboveFloor, 1e-9));
      expect(result.z, closeTo(0.0, 1e-9));
    });

    test('user 3m in front of sign (sign +Z) maps into corridor', () {
      // Sign +Z points into the corridor; with facingAngle=90° that is mall +Z.
      // (0,0,3) → shift: (0, 2.25, 3) → rotate 0°: same → translate (5,0,0).
      final result = signFrameToMallFrame(const Vector3(0, 0, 3), shop90);
      expect(result.x, closeTo(5.0, 1e-9));
      expect(result.y, closeTo(signCenterAboveFloor, 1e-9));
      expect(result.z, closeTo(3.0, 1e-9));
    });

    test('shop facing 0° rotates sign +Z onto mall +X corridor', () {
      // facingAngle=0°, theta = degToRad(0−90) = −π/2, c=0, s=−1
      // User at (0,0,3) in sign frame:
      // shift: (0, 2.25, 3) → rotate: rotX=0*0−3*(−1)=3, rotZ=0*(−1)+3*0=0
      // → (3, 2.25, 0) → translate by (0,0,0): (3, 2.25, 0)
      const shop0 = Shop(
        id: 's',
        name: 'S',
        doorstep: Vector3(0, 0, 0),
        facingAngle: 0.0,
        sign: SignDims(
          widthMeters: 1.0,
          heightMeters: 0.5,
          heightAboveDoorMeters: 2.0,
        ),
      );
      final result = signFrameToMallFrame(const Vector3(0, 0, 3), shop0);
      expect(result.x, closeTo(3.0, 1e-9));
      expect(result.y, closeTo(signCenterAboveFloor, 1e-9));
      expect(result.z, closeTo(0.0, 1e-9));
    });
  });
}
