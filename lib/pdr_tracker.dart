import 'dart:async';
import 'dart:math'as math;
import 'dart:developer';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'ar_navigation_system.dart';

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
  double _mapHeadingRadians = 0.0;
  final double initialMapFacingRadians;
  int _totalSteps = 0;
  DateTime _lastStepTime = DateTime.now();

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
  double _netForwardAccel = 0.0;
  double _netLateralAccel = 0.0;
  int _forwardSampleCount = 0;

  // ── Gravity ──
  double _gravityX = 0, _gravityY = -9.8, _gravityZ = 0;

  // ── Subscriptions ──
  StreamSubscription? _accelSub;
  StreamSubscription? _gravitySub;
  StreamSubscription? _compassSub;

  // ── Callbacks ──
  void Function(Vector3 position)? onPositionUpdate;
  void Function(int totalSteps)? onStepDetected;
  void Function(double headingDegrees)? onHeadingUpdate;
  void Function(String debugInfo)? onDebugUpdate;

  PDRTracker({
    required Vector3 startPosition,
    this.stepLength = 0.65,
    this.minStepInterval = const Duration(milliseconds: 350),
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

    _accelSub = userAccelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(_onAccelData);

    _gravitySub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen(_onGravityData);

    _compassSub = FlutterCompass.events?.listen(_onCompassData);

    log('Started. pos=$_currentPosition stepLen=$stepLength peakTh=$peakThreshold valleyR=$valleyRatio minConsec=$minConsecutiveSteps', name: 'PDR');
  }

  void stop() {
    _accelSub?.cancel(); _gravitySub?.cancel(); _compassSub?.cancel();
    _accelSub = null; _gravitySub = null; _compassSub = null;
    log('Stopped. totalSteps=$_totalSteps finalPos=$_currentPosition', name: 'PDR');
  }

  // ═══════════════════════════════════════════════
  // GRAVITY
  // ═══════════════════════════════════════════════

  void _onGravityData(AccelerometerEvent e) {
    _gravityX = e.x; _gravityY = e.y; _gravityZ = e.z;
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

    // Accumulate direction data during step cycle
    if (_phase != _StepPhase.idle) {
      _netForwardAccel += _getForwardAccel(event);
      _netLateralAccel += _getLateralAccel(event);
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
      'Phase:${_phase.name} Sm:${smoothed.toStringAsFixed(2)} Pk:${_peakValue.toStringAsFixed(2)} Vl:${_valleyValue == double.infinity ? "∞" : _valleyValue.toStringAsFixed(2)}\n'
      'Walk:${_isWalkingLocked ? "LOCKED" : "no(${_consecutiveValidSteps}/$minConsecutiveSteps)"} '
      'Dir:${_netForwardAccel >= 0 ? "FWD" : "BWD"}',
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

    log('✓ Valid cycle #$_consecutiveValidSteps: peak=${_peakValue.toStringAsFixed(2)} valley=${_valleyValue.toStringAsFixed(2)} dur=${cycleDur.inMilliseconds}ms sinceLast=${sinceLast.inMilliseconds}ms', name: 'PDR.VALID');

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
    final dir = _computeDirection();
    final oldPos = _currentPosition;
    _currentPosition = _computeNewPosition(dir);

    log('STEP #$_totalSteps: dir=${dir.toStringAsFixed(2)} heading=${_heading.toStringAsFixed(1)}° mapHead=${(_mapHeadingRadians * 180 / math.pi).toStringAsFixed(1)}° pos $oldPos → $_currentPosition', name: 'PDR');

    onStepDetected?.call(_totalSteps);
    onPositionUpdate?.call(_currentPosition);
  }

  void _onInvalidStep() {
    if (!_isWalkingLocked) _consecutiveValidSteps = 0;
  }

  // ═══════════════════════════════════════════════
  // DIRECTION DETECTION
  // ═══════════════════════════════════════════════

  double _getForwardAccel(UserAccelerometerEvent e) {
    final gm = math.sqrt(_gravityX * _gravityX + _gravityY * _gravityY + _gravityZ * _gravityZ);
    if (gm < 0.1) return e.z;
    final gx = _gravityX/gm, gy = _gravityY/gm, gz = _gravityZ/gm;
    return e.z - (e.x*gx + e.y*gy + e.z*gz) * gz;
  }

  double _getLateralAccel(UserAccelerometerEvent e) {
    final gm = math.sqrt(_gravityX * _gravityX + _gravityY * _gravityY + _gravityZ * _gravityZ);
    if (gm < 0.1) return e.x;
    final gx = _gravityX/gm, gy = _gravityY/gm, gz = _gravityZ/gm;
    return e.x - (e.x*gx + e.y*gy + e.z*gz) * gx;
  }

  double _computeDirection() {
    if (_forwardSampleCount == 0) { log('No direction samples, defaulting to FORWARD', name: 'PDR.DIR'); return 1.0; }
    final avgFwd = _netForwardAccel / _forwardSampleCount;
    final avgLat = _netLateralAccel / _forwardSampleCount;
    log('avgForward=${avgFwd.toStringAsFixed(3)} avgLateral=${avgLat.toStringAsFixed(3)} samples=$_forwardSampleCount', name: 'PDR.DIR');

    if (avgLat.abs() > avgFwd.abs() * 1.5) { log('→ LATERAL movement (half step)', name: 'PDR.DIR'); return 0.5; }
    if (avgFwd < -0.3) { log('→ BACKWARD', name: 'PDR.DIR'); return -1.0; }
    log('→ FORWARD', name: 'PDR.DIR');
    return 1.0;
  }

  Vector3 _computeNewPosition(double dirMul) {
    final eff = stepLength * dirMul;
    final dx = eff * math.cos(_mapHeadingRadians);
    final dz = eff * math.sin(_mapHeadingRadians);
    return Vector3(_currentPosition.x + dx, _currentPosition.y, _currentPosition.z + dz);
  }

  // ═══════════════════════════════════════════════
  // COMPASS
  // ═══════════════════════════════════════════════

  void _onCompassData(CompassEvent event) {
    if (event.heading == null) return;
    final h = event.heading!;
    if (_initialHeading == 0.0 && _totalSteps == 0) {
      _initialHeading = h;
      log('Initial heading set: ${h.toStringAsFixed(1)}°', name: 'PDR.COMPASS');
    }
    _heading = h;
    _mapHeadingRadians = initialMapFacingRadians + (h - _initialHeading) * math.pi / 180.0;
    onHeadingUpdate?.call(h);
  }

  // ═══════════════════════════════════════════════
  // CORRECTIONS
  // ═══════════════════════════════════════════════

  void resetWalkingState() {
    _isWalkingLocked = false; _consecutiveValidSteps = 0; _recentStepIntervals.clear(); _phase = _StepPhase.idle;
    log('Walking state RESET', name: 'PDR');
  }

  void snapToGraph(NavGraph graph) {
    final nid = graph.findNearestNode(_currentPosition);
    final nn = graph.nodes[nid]!;
    final d = _currentPosition.distanceTo(nn.position);
    if (d < 3.0) {
      log('Snapped to "$nid" (was ${d.toStringAsFixed(2)}m away). $currentPosition → ${nn.position}', name: 'PDR.SNAP');
      _currentPosition = nn.position;
    } else {
      log('Too far from nearest node "$nid" (${d.toStringAsFixed(2)}m). No snap.', name: 'PDR.SNAP');
    }
  }

  void correctPosition(Vector3 known) {
    final old = _currentPosition;
    _currentPosition = known;
    log('Position CORRECTED: $old → $known (delta=${old.distanceTo(known).toStringAsFixed(2)}m)', name: 'PDR.CORRECT');
    onPositionUpdate?.call(_currentPosition);
  }
}
