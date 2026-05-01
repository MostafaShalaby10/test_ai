import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:test_sensors/camera_intrinsics.dart';

void main() {
  group('CameraIntrinsics.estimatedFromFov', () {
    test('principal point is at image center', () {
      final intr = CameraIntrinsics.estimatedFromFov(
        width: 1280,
        height: 720,
        horizontalFovDeg: 60.0,
      );
      expect(intr.cx, closeTo(640.0, 1e-9));
      expect(intr.cy, closeTo(360.0, 1e-9));
      expect(intr.width, 1280);
      expect(intr.height, 720);
    });

    test('focal length matches implementation formula: f = (w/2) / (fov_rad/2)', () {
      const width = 1280;
      const fovDeg = 60.0;
      // The implementation uses the half-angle in radians directly (not tan).
      // f = (width/2) / (0.5 * fovDeg * π/180)
      const halfAngleRad = 0.5 * fovDeg * math.pi / 180.0;
      const expected = (width / 2.0) / halfAngleRad;

      final intr = CameraIntrinsics.estimatedFromFov(
        width: width,
        height: 720,
        horizontalFovDeg: fovDeg,
      );
      // 1e-9 guard in denominator is negligible for real FOVs.
      expect(intr.fx, closeTo(expected, 0.01));
      expect(intr.fy, closeTo(expected, 0.01));
    });

    test('fx equals fy (square pixels, no skew)', () {
      final intr = CameraIntrinsics.estimatedFromFov(
        width: 1920,
        height: 1080,
        horizontalFovDeg: 75.0,
      );
      expect(intr.fx, closeTo(intr.fy, 1e-9));
    });

    test('wider FOV produces shorter focal length', () {
      final narrow = CameraIntrinsics.estimatedFromFov(
        width: 1280, height: 720, horizontalFovDeg: 45.0,
      );
      final wide = CameraIntrinsics.estimatedFromFov(
        width: 1280, height: 720, horizontalFovDeg: 90.0,
      );
      expect(narrow.fx, greaterThan(wide.fx));
    });

    test('square sensor has cx == cy when resolution is square', () {
      final intr = CameraIntrinsics.estimatedFromFov(
        width: 720,
        height: 720,
        horizontalFovDeg: 60.0,
      );
      expect(intr.cx, closeTo(intr.cy, 1e-9));
    });
  });
}
