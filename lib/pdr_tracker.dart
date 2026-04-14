// ══════════════════════════════════════════════════════════════════════════════
// pdr_tracker.dart
//
// Pedestrian Dead Reckoning (PDR) — tracks the user's position using
// only the phone's built-in sensors (no ARCore needed):
//
//   Accelerometer → detects steps (counts the up/down bounce of walking)
//   Magnetometer  → compass heading (which direction the user is facing)
//
// How PDR works:
//   1. Detect a step from the accelerometer's vertical oscillation.
//   2. Read the compass heading (0° = North, 90° = East, etc.).
//   3. Move the estimated position forward by one step length
//      in the direction of the compass heading.
//
// Accuracy: ~2-3m drift per 100m walked. Good enough for a mall
// where walks are short and we can snap to the navigation graph.
//
// Dependencies:
//   sensors_plus: ^4.0.0
//   flutter_compass: ^0.8.0
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'ar_navigation_system.dart'; // For Vector3

/// Tracks the user's position using Pedestrian Dead Reckoning.
///
/// Usage:
///   final pdr = PDRTracker(startPosition: Vector3(0, 0, 0));
///   pdr.onPositionUpdate = (pos) => print('User at: $pos');
///   pdr.start();
///   // ... user walks around ...
///   pdr.stop();
class PDRTracker {
  // ── Configuration ──

  /// Average step length in meters. Can be calibrated per user.
  /// Default 0.65m is a reasonable average for adults.
  double stepLength;

  /// Minimum time between detected steps (prevents double-counting).
  /// 300ms ≈ fastest reasonable walking pace.
  final Duration minStepInterval;

  /// Threshold for step detection: the magnitude change in acceleration
  /// that counts as a step. Tuned for phone held in hand while walking.
  final double stepThreshold;

  // ── State ──

  /// The user's current estimated position in map coordinates.
  Vector3 _currentPosition;

  /// Current compass heading in degrees (0 = North, 90 = East).
  double _heading = 0.0;

  /// The initial compass heading when PDR started.
  /// Used to align compass north with map north.
  double _initialHeading = 0.0;

  /// The direction the user is facing in MAP coordinates (radians).
  /// This is computed from: compass heading - initial heading + map facing direction.
  double _mapHeadingRadians = 0.0;

  /// The direction the user is initially facing in the map (radians from +X axis).
  /// Set by the caller based on which way the user is facing at the start node.
  final double initialMapFacingRadians;

  /// Timestamp of the last detected step (to enforce minStepInterval).
  DateTime _lastStepTime = DateTime.now();

  /// Total steps counted since start.
  int _totalSteps = 0;

  /// Running buffer of recent acceleration magnitudes for smoothing.
  final List<double> _accelBuffer = [];
  static const int _bufferSize = 15;

  /// Whether a step is currently in the "high" phase.
  /// Step detection uses a simple peak/valley approach.
  bool _isAboveThreshold = false;

  // ── Subscriptions ──
  StreamSubscription? _accelSubscription;
  StreamSubscription? _compassSubscription;

  // ── Callbacks ──

  /// Called every time the estimated position changes (after each step).
  void Function(Vector3 position)? onPositionUpdate;

  /// Called every time a step is detected.
  void Function(int totalSteps)? onStepDetected;

  /// Called every time the compass heading changes.
  void Function(double headingDegrees)? onHeadingUpdate;

  PDRTracker({
    required Vector3 startPosition,
    this.stepLength = 0.75,
    this.minStepInterval = const Duration(milliseconds: 300),
    this.stepThreshold = 1.1,
    this.initialMapFacingRadians = 0.0, // Default: facing +X direction
  }) : _currentPosition = startPosition;

  /// Current estimated position.
  Vector3 get currentPosition => _currentPosition;

  /// Current compass heading in degrees.
  double get heading => _heading;

  /// The current direction the user is facing in MAP coordinates (radians).
  /// 0 = +X axis, pi/2 = +Z axis.
  double get mapHeadingRadians => _mapHeadingRadians;

  /// Total steps since start.
  int get totalSteps => _totalSteps;

  // ══════════════════════════════════════════════
  // START / STOP
  // ══════════════════════════════════════════════

  /// Starts listening to accelerometer and compass sensors.
  void start() {
    _totalSteps = 0;
    _lastStepTime = DateTime.now();
    _accelBuffer.clear();
    _isAboveThreshold = false;

    // ── Listen to accelerometer for step detection ──
    // We use userAccelerometerEvents which removes gravity,
    // giving us only the user's movement.
    _accelSubscription = userAccelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20), // 50Hz
    ).listen(_onAccelerometerData);

    // ── Listen to compass for heading ──
    _compassSubscription = FlutterCompass.events?.listen(_onCompassData);

    print('[PDR] Started. Initial position: $_currentPosition');
  }

  /// Stops all sensor listeners.
  void stop() {
    _accelSubscription?.cancel();
    _compassSubscription?.cancel();
    _accelSubscription = null;
    _compassSubscription = null;
    print('[PDR] Stopped. Total steps: $_totalSteps');
  }

  // ══════════════════════════════════════════════
  // STEP DETECTION (Accelerometer)
  //
  // Walking creates a rhythmic up-down oscillation in acceleration.
  // We detect steps by finding peaks in the acceleration magnitude
  // that cross above the threshold and then come back down.
  //
  // This is a simplified "peak detection" algorithm:
  //   1. Compute acceleration magnitude: sqrt(x² + y² + z²)
  //   2. Smooth it with a rolling average (reduces noise).
  //   3. When smoothed magnitude crosses above threshold → "peak start"
  //   4. When it crosses back below → one step detected.
  //   5. Enforce minimum time between steps to avoid double-counting.
  // ══════════════════════════════════════════════

  void _onAccelerometerData(UserAccelerometerEvent event) {
    // Calculate the magnitude of acceleration (ignoring direction).
    // For a person walking, this oscillates between ~0 and ~3 m/s².
    final magnitude = sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    // Add to rolling buffer for smoothing.
    _accelBuffer.add(magnitude);
    if (_accelBuffer.length > _bufferSize) {
      _accelBuffer.removeAt(0);
    }

    // Don't process until we have enough samples.
    if (_accelBuffer.length < _bufferSize) return;

    // Compute smoothed (average) magnitude.
    final smoothed = _accelBuffer.reduce((a, b) => a + b) / _accelBuffer.length;

    // ── Peak detection ──
    if (!_isAboveThreshold && smoothed > stepThreshold) {
      // Crossed above threshold — start of a potential step.
      _isAboveThreshold = true;
    } else if (_isAboveThreshold && smoothed < stepThreshold * 0.7) {
      // Crossed back below threshold — step completed.
      _isAboveThreshold = false;

      // Enforce minimum interval between steps.
      final now = DateTime.now();
      if (now.difference(_lastStepTime) >= minStepInterval) {
        _lastStepTime = now;
        _onStepDetected();
      }
    }
  }

  /// Called when a single step is detected.
  void _onStepDetected() {
    _totalSteps++;

    // Move position forward by one step in the current heading direction.
    // Convert compass heading to map movement:
    //   compassHeading = 0° → North → in our map, this maps to a direction
    //   based on initialMapFacingRadians.
    _currentPosition = _computeNewPosition();

    // Fire callbacks.
    onStepDetected?.call(_totalSteps);
    onPositionUpdate?.call(_currentPosition);
  }

  // ══════════════════════════════════════════════
  // COMPASS / HEADING (Magnetometer)
  //
  // The compass gives us absolute heading:
  //   0° = North, 90° = East, 180° = South, 270° = West
  //
  // We need to convert this to map coordinates:
  //   When the user starts, they're facing a known direction on the map
  //   (e.g., facing +X, or facing +Z, etc.).
  //   The compass tells us they're facing, say, 45° (NE).
  //
  //   If they turn 30° right, compass goes to 75°.
  //   The CHANGE in compass (75° - 45° = 30°) is what matters.
  //   We apply that change to their initial map facing direction.
  // ══════════════════════════════════════════════

  void _onCompassData(CompassEvent event) {
    if (event.heading == null) return;

    final newHeading = event.heading!;

    // On the very first reading, record the initial heading.
    if (_initialHeading == 0.0 && _totalSteps == 0) {
      _initialHeading = newHeading;
    }

    _heading = newHeading;

    // Compute the change in heading since start.
    // (how much the user has turned from their starting direction)
    final headingChange = (newHeading - _initialHeading) * pi / 180.0;

    // Apply the change to the initial map facing direction.
    _mapHeadingRadians = initialMapFacingRadians + headingChange;

    onHeadingUpdate?.call(newHeading);
  }

  // ══════════════════════════════════════════════
  // POSITION COMPUTATION
  //
  // When a step is detected, move the position forward by stepLength
  // in the direction of the current map heading.
  //
  // Map coordinate system:
  //   X → left/right
  //   Z → forward/backward
  //   Y → up/down (stays constant on the same floor)
  //
  // So one step moves:
  //   deltaX = stepLength * cos(mapHeading)
  //   deltaZ = stepLength * sin(mapHeading)
  // ══════════════════════════════════════════════

  Vector3 _computeNewPosition() {
    final dx = stepLength * cos(_mapHeadingRadians);
    final dz = stepLength * sin(_mapHeadingRadians);

    return Vector3(
      _currentPosition.x + dx,
      _currentPosition.y, // Y stays the same (same floor)
      _currentPosition.z + dz,
    );
  }

  /// Snap the current position to the nearest point on the graph corridors (edges).
  /// This corrects drift by pulling the estimated position back onto
  /// valid walkable areas. Call periodically (e.g., every 5 steps).
  void snapToGraph(NavGraph graph) {
    final snappedPosition = graph.findNearestPointOnGraph(_currentPosition);
    final distance = _currentPosition.distanceTo(snappedPosition);

    // Only snap if we're within a reasonable distance (2.5m).
    // If we're too far, snapping would teleport the user.
    if (distance < 2.5) {
      // Small smoothing: move 70% toward the snapped point to avoid jitter.
      _currentPosition = Vector3(
        _currentPosition.x + (snappedPosition.x - _currentPosition.x) * 0.7,
        snappedPosition.y,
        _currentPosition.z + (snappedPosition.z - _currentPosition.z) * 0.7,
      );
    }
  }

  /// Manually correct the position (e.g., when user scans a QR code
  /// or reaches a known landmark).
  void correctPosition(Vector3 knownPosition) {
    _currentPosition = knownPosition;
    onPositionUpdate?.call(_currentPosition);
  }
}
