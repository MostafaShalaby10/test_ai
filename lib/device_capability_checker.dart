import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:developer';

enum NavigationTier { fullAR, sensorAR, map2D }

class DeviceCapabilityChecker {
  static Future<NavigationTier> detectTier() async {
    log('Detecting device capabilities...', name: 'CAP');

    final hasAR = await _checkARCore();
    log('ARCore: $hasAR', name: 'CAP');
    if (hasAR) { log('→ TIER 1: Full AR', name: 'CAP'); return NavigationTier.fullAR; }

    final hasGyro = await _checkGyroscope();
    final hasMag = await _checkMagnetometer();
    log('Gyroscope: $hasGyro, Magnetometer: $hasMag', name: 'CAP');
    if (hasGyro && hasMag) { log('→ TIER 2: Sensor AR', name: 'CAP'); return NavigationTier.sensorAR; }

    log('→ TIER 3: 2D Map', name: 'CAP');
    return NavigationTier.map2D;
  }

  static Future<bool> _checkARCore() async {
    try {
      const platform = MethodChannel('ar_navigation/capability');
      final bool r = await platform.invokeMethod('checkARCore');
      log('ARCore platform channel returned: $r', name: 'CAP');
      return r;
    } catch (e) {
      log('ARCore check failed: $e', name: 'CAP');
      return false;
    }
  }

  static Future<bool> _checkGyroscope() async {
    try {
      final c = Completer<bool>();
      final sub = gyroscopeEventStream().listen(
        (e) { if (!c.isCompleted) c.complete(true); },
        onError: (e) { if (!c.isCompleted) c.complete(false); },
      );
      final r = await c.future.timeout(const Duration(seconds: 1), onTimeout: () => false);
      await sub.cancel();
      return r;
    } catch (e) { log('Gyroscope check error: $e', name: 'CAP'); return false; }
  }

  static Future<bool> _checkMagnetometer() async {
    try {
      final c = Completer<bool>();
      final sub = magnetometerEventStream().listen(
        (e) { if (!c.isCompleted) c.complete(true); },
        onError: (e) { if (!c.isCompleted) c.complete(false); },
      );
      final r = await c.future.timeout(const Duration(seconds: 1), onTimeout: () => false);
      await sub.cancel();
      return r;
    } catch (e) { log('Magnetometer check error: $e', name: 'CAP'); return false; }
  }

  static String tierDescription(NavigationTier t) {
    switch (t) {
      case NavigationTier.fullAR: return 'Full AR Navigation (ARCore)';
      case NavigationTier.sensorAR: return 'Sensor AR Navigation (Camera + Compass)';
      case NavigationTier.map2D: return '2D Map Navigation';
    }
  }
}
