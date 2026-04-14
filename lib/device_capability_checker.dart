// ══════════════════════════════════════════════════════════════════════════════
// device_capability_checker.dart
//
// Detects what navigation capabilities the device supports:
//   Tier 1: ARCore/ARKit   → Full 3D AR navigation
//   Tier 2: Gyroscope + Compass → Sensor-based AR (camera + PDR + overlay)
//   Tier 3: None of above  → 2D map with turn-by-turn directions
//
// Usage:
//   final tier = await DeviceCapabilityChecker.detectTier();
//   // tier == NavigationTier.fullAR / sensorAR / map2D
// ══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';

/// The three tiers of navigation experience.
enum NavigationTier {
  /// Tier 1: Full ARCore/ARKit with 3D avatar placement.
  /// Best experience — requires ARCore-certified device.
  fullAR,

  /// Tier 2: Camera feed + compass heading + step counting.
  /// Works on any phone with gyroscope and magnetometer.
  sensorAR,

  /// Tier 3: Static 2D floor plan with animated path.
  /// Works on literally any phone with a screen.
  map2D,
}

class DeviceCapabilityChecker {
  /// Detects the highest navigation tier this device supports.
  ///
  /// Checks in order:
  ///   1. Is ARCore/ARKit available? → Tier 1 (fullAR)
  ///   2. Does the phone have gyroscope + magnetometer? → Tier 2 (sensorAR)
  ///   3. Neither → Tier 3 (map2D)
  static Future<NavigationTier> detectTier() async {
    // ── Check Tier 1: ARCore availability ──
    final hasARCore = await _checkARCoreAvailability();
    if (hasARCore) {
      return NavigationTier.fullAR;
    }

    // ── Check Tier 2: Sensor availability ──
    final hasGyroscope = await _checkGyroscope();
    final hasMagnetometer = await _checkMagnetometer();

    if (hasGyroscope && hasMagnetometer) {
      return NavigationTier.sensorAR;
    }

    // ── Tier 3: Fallback ──
    return NavigationTier.map2D;
  }

  /// Checks if ARCore (Android) or ARKit (iOS) is available.
  ///
  /// Uses a platform channel to call the native ARCore availability check.
  /// On Android: ArCoreApk.getInstance().checkAvailability()
  /// On iOS: ARWorldTrackingConfiguration.isSupported
  static Future<bool> _checkARCoreAvailability() async {
    try {
      // Platform channel to check ARCore.
      // You need to implement this on the native side (see below).
      const platform = MethodChannel('ar_navigation/capability');
      final bool isAvailable = await platform.invokeMethod('checkARCore');
      return isAvailable;
    } catch (e) {
      // If the channel isn't set up or throws, ARCore is not available.
      print('[Capability] ARCore check failed: $e');
      return false;
    }
  }

  /// Checks if the device has a gyroscope by listening for a single event.
  ///
  /// We set a short timeout — if no data arrives, the sensor doesn't exist.
  static Future<bool> _checkGyroscope() async {
    try {
      final completer = Completer<bool>();

      // Listen for one gyroscope event with a 1-second timeout.
      final subscription = gyroscopeEventStream().listen(
        (event) {
          if (!completer.isCompleted) completer.complete(true);
        },
        onError: (e) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      // If no event arrives within 1 second, assume no gyroscope.
      final result = await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => false,
      );

      await subscription.cancel();
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Checks if the device has a magnetometer (compass) sensor.
  static Future<bool> _checkMagnetometer() async {
    try {
      final completer = Completer<bool>();

      final subscription = magnetometerEventStream().listen(
        (event) {
          if (!completer.isCompleted) completer.complete(true);
        },
        onError: (e) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      final result = await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => false,
      );

      await subscription.cancel();
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Returns a human-readable description of the detected tier.
  static String tierDescription(NavigationTier tier) {
    switch (tier) {
      case NavigationTier.fullAR:
        return 'Full AR Navigation (ARCore)';
      case NavigationTier.sensorAR:
        return 'Sensor AR Navigation (Camera + Compass)';
      case NavigationTier.map2D:
        return '2D Map Navigation';
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// NATIVE SIDE SETUP
//
// You need to add a MethodChannel handler on the native Android side
// to check ARCore availability. Add this to your MainActivity.kt:
//
// ```kotlin
// import com.google.ar.core.ArCoreApk
// import io.flutter.embedding.android.FlutterActivity
// import io.flutter.embedding.engine.FlutterEngine
// import io.flutter.plugin.common.MethodChannel
//
// class MainActivity : FlutterActivity() {
//     override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
//         super.configureFlutterEngine(flutterEngine)
//
//         MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
//             "ar_navigation/capability"
//         ).setMethodCallHandler { call, result ->
//             if (call.method == "checkARCore") {
//                 val availability = ArCoreApk.getInstance()
//                     .checkAvailability(this)
//                 result.success(
//                     availability == ArCoreApk.Availability.SUPPORTED_INSTALLED ||
//                     availability == ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD ||
//                     availability == ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED
//                 )
//             } else {
//                 result.notImplemented()
//             }
//         }
//     }
// }
// ```
// ══════════════════════════════════════════════════════════════════════════════
