import 'dart:developer';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

// ═══════════════════════════════════════════════════════════════
// CameraIntrinsics — pinhole camera model values fx, fy, cx, cy,
// reported in the pixel space of `previewWidth × previewHeight`.
//
// solvePnP needs these to convert 2D sign-corner pixels into a 3D
// camera pose. They are *device-specific*; hardcoding values from a
// Pixel 7 onto an iPhone wrecks accuracy (plan line 124).
// ═══════════════════════════════════════════════════════════════

class CameraIntrinsics {
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final int width;
  final int height;

  const CameraIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });

  @override
  String toString() =>
      'CameraIntrinsics(fx=${fx.toStringAsFixed(1)}, fy=${fy.toStringAsFixed(1)}, '
      'cx=${cx.toStringAsFixed(1)}, cy=${cy.toStringAsFixed(1)}, '
      '${width}x$height)';

  /// Fallback intrinsics derived from a guessed 60° horizontal FOV.
  /// Used when the native channel fails — better than crashing, worse
  /// than a real calibration. Callers should log a warning.
  factory CameraIntrinsics.estimatedFromFov({
    required int width,
    required int height,
    double horizontalFovDeg = 60.0,
  }) {
    // focal_px = (width/2) / tan(fov/2)
    final f = (width / 2.0) /
        (1e-9 + (0.5 * horizontalFovDeg * 3.14159265358979 / 180.0));
    return CameraIntrinsics(
      fx: f,
      fy: f,
      cx: width / 2.0,
      cy: height / 2.0,
      width: width,
      height: height,
    );
  }
}

class CameraIntrinsicsChannel {
  static const MethodChannel _channel =
      MethodChannel('mall_nav/camera_intrinsics');

  // Per-camera cache so repeat calls are free.
  static final Map<String, CameraIntrinsics> _cache = {};

  /// Query native intrinsics for the given camera + preview resolution.
  ///
  /// `cameraId` is the platform-specific ID: on Android it's the value
  /// from `CameraManager.getCameraIdList()` (usually "0" for back); on
  /// iOS it's a best-effort device identifier (can be empty — we fall
  /// back to the default back camera).
  ///
  /// If the native side fails, returns an FOV-estimated fallback.
  static Future<CameraIntrinsics> fetch({
    required String cameraId,
    required int previewWidth,
    required int previewHeight,
  }) async {
    final cacheKey = '$cameraId@${previewWidth}x$previewHeight';
    final hit = _cache[cacheKey];
    if (hit != null) return hit;

    if (!(Platform.isAndroid || Platform.isIOS)) {
      log('Non-mobile platform — using FOV fallback', name: 'INTRINSICS');
      final fallback = CameraIntrinsics.estimatedFromFov(
        width: previewWidth,
        height: previewHeight,
      );
      _cache[cacheKey] = fallback;
      return fallback;
    }

    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getIntrinsics',
        {
          'cameraId': cameraId,
          'previewWidth': previewWidth,
          'previewHeight': previewHeight,
        },
      );
      if (res == null) throw PlatformException(code: 'null_result');

      final intr = CameraIntrinsics(
        fx: (res['fx'] as num).toDouble(),
        fy: (res['fy'] as num).toDouble(),
        cx: (res['cx'] as num).toDouble(),
        cy: (res['cy'] as num).toDouble(),
        width: (res['width'] as num).toInt(),
        height: (res['height'] as num).toInt(),
      );
      log('Fetched $intr for $cacheKey', name: 'INTRINSICS');
      _cache[cacheKey] = intr;
      return intr;
    } catch (e) {
      log('Native intrinsics failed ($e) — using FOV fallback',
          name: 'INTRINSICS');
      final fallback = CameraIntrinsics.estimatedFromFov(
        width: previewWidth,
        height: previewHeight,
      );
      _cache[cacheKey] = fallback;
      return fallback;
    }
  }

  /// For debug UI. Clears the in-memory cache so a re-fetch hits native.
  static void clearCache() => _cache.clear();
}

/// Live ARKit / ARCore-derived intrinsics for the AR snapshot used by
/// Tier 1's scan-on-tap visual fix. Reads the AR session's projection matrix
/// for the active view and converts it to pinhole intrinsics in snapshot
/// pixel space — captures FOV, aspect cropping, and device orientation
/// correctly. iOS uses ARKit's `currentFrame.camera.projectionMatrix`;
/// Android uses ARCore's `Camera.getProjectionMatrix` via reflection on
/// sceneview's `ARSceneView`. Returns null on desktop / when no AR view is
/// active / on platforms with no implementation.
class ARIntrinsicsChannel {
  static const MethodChannel _channel = MethodChannel('mall_nav/ar_intrinsics');

  static Future<CameraIntrinsics?> fetchSnapshotIntrinsics() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return null;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getARSnapshotIntrinsics',
      );
      if (res == null) return null;
      return CameraIntrinsics(
        fx: (res['fx'] as num).toDouble(),
        fy: (res['fy'] as num).toDouble(),
        cx: (res['cx'] as num).toDouble(),
        cy: (res['cy'] as num).toDouble(),
        width: (res['width'] as num).toInt(),
        height: (res['height'] as num).toInt(),
      );
    } catch (e) {
      log('AR snapshot intrinsics fetch failed ($e)', name: 'INTRINSICS');
      return null;
    }
  }
}
