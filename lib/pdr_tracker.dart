import 'dart:async';
import 'dart:math'as math;
import 'dart:developer';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'ar_navigation_system.dart';
import 'mall_geometry.dart' as geom;

enum _StepPhase { idle, rising, falling, valley }

class PDRTracker {
  // ── Config ──
  double stepLength;
  final Duration minStepInterval;
  final Duration maxStepDuration;
  final double peakThreshold;
  final double valleyRatio;
  final int minConsecutiveSteps;
  final int _rhythmWindowSize = 5;

  // ── Position state ──
  Vector3 _currentPosition;
  double _heading = 0.0;
  double _initialHeading = 0.0;
  bool _initialHeadingSet = false;
  double _mapHeadingRadians = 0.0;
  final double initialMapFacingRadians;
  int _totalSteps = 0;
  DateTime _lastStepTime = DateTime.now();
  DateTime _lastCompassInvalidLog = DateTime.fromMillisecondsSinceEpoch(0);
  int _invalidCompassCount = 0;

  // ── Drift tracking ──
  // Reset on every visual / manual fix. UI uses these to de-emphasize
  // the position pin and prompt for a rescan after thresholds are passed.
  int _stepsSinceLastFix = 0;
  DateTime? _lastFixAt;

  // ── Heading smoothing ──
  // iOS reports heading accuracy in degrees; indoors we've seen 12°–40°.
  // Raw readings jump 70°+ step-to-step, which turns every walking vector
  // into noise. We gate on accuracy and average over a rolling window using
  // a circular mean so 359° + 1° averages to 0°, not 180°.
  static const double _maxHeadingAccuracyDegrees = 25.0;
  static const int _headingSmoothWindow = 10;
  static const int _headingMinSamplesForInit = 5;
  final List<double> _headingBufferCos = [];
  final List<double> _headingBufferSin = [];

  // ── Step state machine ──
  _StepPhase _phase = _StepPhase.idle;
  DateTime _cycleStartTime = DateTime.now();
  double _peakValue = 0.0;
  double _valleyValue = double.infinity;

  // ── Smoothing ──
  final List<double> _accelBuffer = [];
  static const int _bufferSize = 6;

  // ── Walking lock ──
  int _consecutiveValidSteps = 0;
  final List<Duration> _recentStepIntervals = [];
  bool _isWalkingLocked = false;

  // ── Direction detection ──
  // UserAccelerometerEvent is gravity-free (OS already subtracts it).
  // We accumulate e.z (forward/back along phone body) and e.x (lateral) directly.
  // Net sign of the Z integral over a step cycle tells us forward vs backward.
  double _netForwardAccel = 0.0;
  double _netLateralAccel = 0.0;
  int _forwardSampleCount = 0;

  // ── Subscriptions ──
  StreamSubscription? _accelSub;
  StreamSubscription? _compassSub;

  // ── Callbacks ──
  void Function(Vector3 position)? onPositionUpdate;
  void Function(int totalSteps)? onStepDetected;
  void Function(double headingDegrees)? onHeadingUpdate;
  void Function(String debugInfo)? onDebugUpdate;

  PDRTracker({
    required Vector3 startPosition,
    this.stepLength = 0.65,
    // FIX: lowered from 350ms → 200ms. Logs showed real walking cycles of
    // 100–320ms being rejected; 200ms keeps noise protection while accepting
    // faster natural cadences.
    this.minStepInterval = const Duration(milliseconds: 200),
    this.maxStepDuration = const Duration(milliseconds: 2000),
    this.peakThreshold = 1.2,
    this.valleyRatio = 0.7,
    this.minConsecutiveSteps = 2,
    this.initialMapFacingRadians = 0.0,
  }) : _currentPosition = startPosition;

  Vector3 get currentPosition => _currentPosition;
  double get heading => _heading;
  double get initialHeading => _initialHeading;
  int get totalSteps => _totalSteps;
  bool get isWalkingDetected => _isWalkingLocked;
  int get stepsSinceLastFix => _stepsSinceLastFix;
  DateTime? get lastFixAt => _lastFixAt;

  // ═══════════════════════════════════════════════
  // START / STOP
  // ═══════════════════════════════════════════════

  void start() {
    _totalSteps = 0;
    _lastStepTime = DateTime.now();
    _accelBuffer.clear();
    _phase = _StepPhase.idle;
    _consecutiveValidSteps = 0;
    _isWalkingLocked = false;
    _recentStepIntervals.clear();
    _initialHeadingSet = false;
    _invalidCompassCount = 0;
    _headingBufferCos.clear();
    _headingBufferSin.clear();

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        _accelSub = userAccelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 20),
        ).listen(
          _onAccelData,
          onError: (e) => log('Accel stream error: $e', name: 'PDR'),
          cancelOnError: true,
        );
      } catch (e) { log('Accel init error: $e', name: 'PDR'); }

      try {
        _compassSub = FlutterCompass.events?.listen(
          _onCompassData,
          onError: (e) => log('Compass stream error: $e', name: 'PDR'),
          cancelOnError: true,
        );
      } catch (e) { log('Compass init error: $e', name: 'PDR'); }
    } else {
      log('Desktop/Web detected. Hardware sensors disabled.', name: 'PDR');
    }

    log('Started. pos=$_currentPosition stepLen=$stepLength peakTh=$peakThreshold '
        'valleyR=$valleyRatio minConsec=$minConsecutiveSteps '
        'minInterval=${minStepInterval.inMilliseconds}ms', name: 'PDR');
  }

  void stop() {
    try { _accelSub?.cancel(); } catch (e) { log('Accel cancel error: $e', name: 'PDR'); }
    try { _compassSub?.cancel(); } catch (e) { log('Compass cancel error: $e', name: 'PDR'); }
    _accelSub = null; _compassSub = null;
    log('Stopped. totalSteps=$_totalSteps finalPos=$_currentPosition', name: 'PDR');
  }

  // ═══════════════════════════════════════════════
  // ACCELEROMETER → Step Detection State Machine
  // ═══════════════════════════════════════════════

  void _onAccelData(UserAccelerometerEvent event) {
    final mag = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

    _accelBuffer.add(mag);
    if (_accelBuffer.length > _bufferSize) _accelBuffer.removeAt(0);
    if (_accelBuffer.length < _bufferSize) return;

    final smoothed = _accelBuffer.reduce((a, b) => a + b) / _accelBuffer.length;

    // Accumulate raw axis data for direction detection during the step cycle.
    if (_phase != _StepPhase.idle) {
      _netForwardAccel += event.z; // gravity-free; +z = forward when phone upright
      _netLateralAccel += event.x; // gravity-free; +x = right
      _forwardSampleCount++;
    }

    // ── State machine ──
    switch (_phase) {
      case _StepPhase.idle:
        if (smoothed > peakThreshold * 0.5) {
          _phase = _StepPhase.rising;
          _cycleStartTime = DateTime.now();
          _peakValue = smoothed;
          _valleyValue = double.infinity;
          _netForwardAccel = 0; _netLateralAccel = 0; _forwardSampleCount = 0;
          log('IDLE→RISING smoothed=${smoothed.toStringAsFixed(3)}', name: 'PDR.STEP');
        }
        break;

      case _StepPhase.rising:
        if (smoothed > _peakValue) _peakValue = smoothed;
        if (smoothed < _peakValue * 0.8 && _peakValue > peakThreshold) {
          _phase = _StepPhase.falling;
          log('RISING→FALLING peak=${_peakValue.toStringAsFixed(3)} cur=${smoothed.toStringAsFixed(3)}', name: 'PDR.STEP');
        }
        if (DateTime.now().difference(_cycleStartTime) > maxStepDuration) {
          log('RISING→IDLE timeout (${DateTime.now().difference(_cycleStartTime).inMilliseconds}ms)', name: 'PDR.STEP');
          _resetCycle();
        }
        break;

      case _StepPhase.falling:
        if (smoothed < _valleyValue) _valleyValue = smoothed;
        if (_valleyValue < _peakValue * valleyRatio) {
          _phase = _StepPhase.valley;
          log('FALLING→VALLEY valley=${_valleyValue.toStringAsFixed(3)} threshold=${(_peakValue * valleyRatio).toStringAsFixed(3)}', name: 'PDR.STEP');
        }
        if (smoothed > _valleyValue * 1.5 && _valleyValue > _peakValue * valleyRatio) {
          log('FALLING→IDLE rising again without deep valley. valley=${_valleyValue.toStringAsFixed(3)}', name: 'PDR.STEP');
          _resetCycle();
        }
        if (DateTime.now().difference(_cycleStartTime) > maxStepDuration) {
          log('FALLING→IDLE timeout', name: 'PDR.STEP');
          _resetCycle();
        }
        break;

      case _StepPhase.valley:
        log('VALLEY→validate peak=${_peakValue.toStringAsFixed(3)} valley=${_valleyValue.toStringAsFixed(3)}', name: 'PDR.STEP');
        _validateAndCountStep();
        _resetCycle();
        break;
    }

    onDebugUpdate?.call(
      'Phase:${_phase.name} Sm:${smoothed.toStringAsFixed(2)} Pk:${_peakValue.toStringAsFixed(2)} '
      'Vl:${_valleyValue == double.infinity ? "∞" : _valleyValue.toStringAsFixed(2)}\n'
      'Walk:${_isWalkingLocked ? "LOCKED" : "no(${_consecutiveValidSteps}/$minConsecutiveSteps)"} '
      'Dir:${_forwardSampleCount > 0 ? (_netForwardAccel / _forwardSampleCount >= 0 ? "FWD" : "BWD") : "?"}',
    );
  }

  void _resetCycle() { _phase = _StepPhase.idle; _peakValue = 0; _valleyValue = double.infinity; }

  // ═══════════════════════════════════════════════
  // STEP VALIDATION
  // ═══════════════════════════════════════════════

  void _validateAndCountStep() {
    final now = DateTime.now();
    final cycleDur = now.difference(_cycleStartTime);
    final sinceLast = now.difference(_lastStepTime);

    // Check 1: Peak amplitude
    if (_peakValue < peakThreshold) {
      log('REJECT: peak too low ${_peakValue.toStringAsFixed(3)} < $peakThreshold', name: 'PDR.VALID');
      _onInvalidStep();
      return;
    }

    // Check 2: Cycle too fast
    if (cycleDur < minStepInterval) {
      log('REJECT: too fast ${cycleDur.inMilliseconds}ms < ${minStepInterval.inMilliseconds}ms', name: 'PDR.VALID');
      _onInvalidStep();
      return;
    }

    // Check 3: Cycle too slow
    if (cycleDur > maxStepDuration) {
      log('REJECT: too slow ${cycleDur.inMilliseconds}ms > ${maxStepDuration.inMilliseconds}ms', name: 'PDR.VALID');
      _onInvalidStep();
      return;
    }

    // Check 4: Long gap → reset rhythm (but don't reject)
    if (sinceLast > const Duration(seconds: 3)) {
      _recentStepIntervals.clear();
      log('Long gap ${sinceLast.inMilliseconds}ms. Rhythm reset.', name: 'PDR.VALID');
    }

    // ── Valid step! ──
    _consecutiveValidSteps++;
    _lastStepTime = now;
    _recentStepIntervals.add(sinceLast);
    if (_recentStepIntervals.length > _rhythmWindowSize) _recentStepIntervals.removeAt(0);

    log('✓ Valid cycle #$_consecutiveValidSteps: peak=${_peakValue.toStringAsFixed(2)} '
        'valley=${_valleyValue.toStringAsFixed(2)} dur=${cycleDur.inMilliseconds}ms '
        'sinceLast=${sinceLast.inMilliseconds}ms', name: 'PDR.VALID');

    // Check 5: Lock
    if (_consecutiveValidSteps >= minConsecutiveSteps) {
      if (!_isWalkingLocked) log('★ Walking LOCKED after $_consecutiveValidSteps consecutive steps', name: 'PDR');
      _isWalkingLocked = true;
    }

    if (!_isWalkingLocked) {
      log('Candidate #$_consecutiveValidSteps (need $minConsecutiveSteps to lock). NOT moving position yet.', name: 'PDR');
      return;
    }

    // ── Count and move ──
    _totalSteps++;
    _stepsSinceLastFix++;
    final dir = _computeDirection();
    final oldPos = _currentPosition;
    _currentPosition = _computeNewPosition(dir);

    log('STEP #$_totalSteps: dir=${dir.toStringAsFixed(2)} heading=${_heading.toStringAsFixed(1)}° '
        'mapHead=${(_mapHeadingRadians * 180 / math.pi).toStringAsFixed(1)}° '
        'pos $oldPos → $_currentPosition', name: 'PDR');

    onStepDetected?.call(_totalSteps);
    onPositionUpdate?.call(_currentPosition);
  }

  void _onInvalidStep() {
    if (!_isWalkingLocked) _consecutiveValidSteps = 0;
  }

  // ═══════════════════════════════════════════════
  // DIRECTION DETECTION
  // ═══════════════════════════════════════════════
  //
  // We only distinguish forward from lateral (side-step). Backward detection
  // via body-frame accelerometer is not reliable: the phone's orientation
  // shifts with hand/arm position during walking, so the sign of net +Z
  // acceleration is noise-dominated. Field logs showed ~20% of forward
  // steps misclassified as BACKWARD, which flipped the walking vector and
  // produced random-walk drift.
  //
  // Proper forward/backward distinction needs world-frame sensor fusion
  // (raw accel for gravity + gyro integration + heading) which requires
  // per-device calibration. Until that exists, forward-only is strictly
  // more accurate: indoor nav is ~99% forward walking, and treating all
  // locked steps as forward eliminates the sign-flip failure mode.

  double _computeDirection() {
    if (_forwardSampleCount == 0) {
      log('No direction samples, defaulting to FORWARD', name: 'PDR.DIR');
      return 1.0;
    }
    final avgFwd = _netForwardAccel / _forwardSampleCount;
    final avgLat = _netLateralAccel / _forwardSampleCount;
    log('avgZ(fwd)=${avgFwd.toStringAsFixed(3)} avgX(lat)=${avgLat.toStringAsFixed(3)} samples=$_forwardSampleCount', name: 'PDR.DIR');

    if (avgLat.abs() > avgFwd.abs() * 2.0) {
      log('→ LATERAL movement (half step)', name: 'PDR.DIR');
      return 0.5;
    }
    log('→ FORWARD', name: 'PDR.DIR');
    return 1.0;
  }

  Vector3 _computeNewPosition(double dirMul) {
    final eff = stepLength * dirMul;
    // Route through the single-source-of-truth step helper so any future
    // change to the step-displacement convention happens in one file.
    return geom.pdrStep(_currentPosition, geom.radToDeg(_mapHeadingRadians), eff);
  }

  // ═══════════════════════════════════════════════
  // COMPASS
  // ═══════════════════════════════════════════════

  void _onCompassData(CompassEvent event) {
    final h = event.heading;
    final acc = event.accuracy;

    // iOS returns heading = -1 when the magnetometer is uncalibrated or
    // CoreLocation has no fix. Accuracy < 0 means unreliable on both platforms.
    // We also reject readings with accuracy worse than the threshold; indoors
    // those carry ±25°+ error which swings the walking vector step-to-step.
    final invalid = h == null ||
        h < 0 ||
        (acc != null && (acc < 0 || acc > _maxHeadingAccuracyDegrees));
    if (invalid) {
      _invalidCompassCount++;
      final now = DateTime.now();
      if (now.difference(_lastCompassInvalidLog).inSeconds >= 3) {
        log('Invalid reading (h=$h acc=$acc count=$_invalidCompassCount). '
            'Phone compass likely uncalibrated or too noisy — move device in '
            'a figure-8 away from metal/electronics and ensure location '
            'permission is granted.', name: 'PDR.COMPASS');
        _lastCompassInvalidLog = now;
      }
      return;
    }

    // Append to circular-mean buffer. Converting each heading to (cos, sin)
    // then averaging handles the 0°/360° wrap correctly.
    final rad = h * math.pi / 180.0;
    _headingBufferCos.add(math.cos(rad));
    _headingBufferSin.add(math.sin(rad));
    if (_headingBufferCos.length > _headingSmoothWindow) {
      _headingBufferCos.removeAt(0);
      _headingBufferSin.removeAt(0);
    }

    final avgCos = _headingBufferCos.reduce((a, b) => a + b) / _headingBufferCos.length;
    final avgSin = _headingBufferSin.reduce((a, b) => a + b) / _headingBufferSin.length;
    final smoothed = geom.normalizeAngle(math.atan2(avgSin, avgCos) * 180.0 / math.pi);

    // Don't latch _initialHeading on the very first (noisy) sample; wait for
    // enough samples so the reference is stable.
    if (!_initialHeadingSet) {
      if (_headingBufferCos.length < _headingMinSamplesForInit) return;
      _initialHeading = smoothed;
      _initialHeadingSet = true;
      log('Initial heading set: ${smoothed.toStringAsFixed(1)}° '
          '(accuracy=$acc, smoothed over $_headingMinSamplesForInit samples, '
          'rejected $_invalidCompassCount invalid readings first)',
          name: 'PDR.COMPASS');
    }
    _heading = smoothed;
    _mapHeadingRadians = initialMapFacingRadians +
        (smoothed - _initialHeading) * math.pi / 180.0;
    onHeadingUpdate?.call(smoothed);
  }

  // ═══════════════════════════════════════════════
  // CORRECTIONS
  // ═══════════════════════════════════════════════

  void resetWalkingState() {
    _isWalkingLocked = false; _consecutiveValidSteps = 0; _recentStepIntervals.clear(); _phase = _StepPhase.idle;
    log('Walking state RESET', name: 'PDR');
  }

  // Snap to the nearest node in an explicit candidate list (typically the
  // current and upcoming waypoints). Passed-waypoint and unrelated graph
  // nodes must be filtered out by the caller — snapping to them drags the
  // PDR backward along the route.
  void snapToNodes(List<NavNode> candidates, {double maxDist = 3.0}) {
    if (candidates.isEmpty) return;
    NavNode nearest = candidates.first;
    double best = _currentPosition.distanceTo(nearest.position);
    for (int i = 1; i < candidates.length; i++) {
      final d = _currentPosition.distanceTo(candidates[i].position);
      if (d < best) { best = d; nearest = candidates[i]; }
    }
    if (best < maxDist) {
      log('Snapped to "${nearest.id}" (was ${best.toStringAsFixed(2)}m away, '
          '${candidates.length} path candidates). $_currentPosition → ${nearest.position}',
          name: 'PDR.SNAP');
      _currentPosition = nearest.position;
    } else {
      log('Too far from nearest path node "${nearest.id}" (${best.toStringAsFixed(2)}m). No snap.',
          name: 'PDR.SNAP');
    }
  }

  void correctPosition(Vector3 known) {
    final old = _currentPosition;
    _currentPosition = known;
    _stepsSinceLastFix = 0;
    _lastFixAt = DateTime.now();
    log('Position CORRECTED: $old → $known (delta=${old.distanceTo(known).toStringAsFixed(2)}m)', name: 'PDR.CORRECT');
    onPositionUpdate?.call(_currentPosition);
  }

  // Visual fix that supplies BOTH position and heading. Adjusts the
  // initial-heading reference so the current compass reading maps to
  // the supplied mall heading — i.e. treats vision as ground truth on
  // disagreement (per the plan's risks section: trust vision over
  // magnetometer indoors).
  //
  // mallHeadingDeg is in mall-degrees (CCW from +X, [0,360)). The PDR's
  // internal _mapHeadingRadians is offset from initialMapFacingRadians,
  // so we solve for the new _initialHeading such that
  //   (_heading - newInitial) * π/180 + initialMapFacingRadians
  //     == mallHeadingDeg * π/180
  @visibleForTesting
  void setInitialHeadingForTest(double compassDeg) {
    _heading = compassDeg;
    _initialHeading = compassDeg;
    _initialHeadingSet = true;
  }

  void correctPositionAndHeading(Vector3 known, double mallHeadingDeg) {
    correctPosition(known);
    if (!_initialHeadingSet) {
      log('correctPositionAndHeading called before compass latched — '
          'will only correct position', name: 'PDR.CORRECT');
      return;
    }
    final initialMapFacingDeg = initialMapFacingRadians * 180.0 / math.pi;
    _initialHeading = _heading - (mallHeadingDeg - initialMapFacingDeg);
    // Keep _mapHeadingRadians consistent so the next step uses the new ref.
    _mapHeadingRadians = initialMapFacingRadians +
        (_heading - _initialHeading) * math.pi / 180.0;
    log('Heading CORRECTED: now mapped to ${mallHeadingDeg.toStringAsFixed(1)}° '
        'mall (compass=${_heading.toStringAsFixed(1)}°, '
        'newInitialRef=${_initialHeading.toStringAsFixed(1)}°)',
        name: 'PDR.CORRECT');
    onHeadingUpdate?.call(_heading);
  }
}
