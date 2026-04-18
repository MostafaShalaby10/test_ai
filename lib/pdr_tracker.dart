import 'dart:async';
import 'dart:math'as math;
import 'dart:developer';
import 'dart:io' show Platform;
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
  // FIX: The old code projected a gravity-free UserAccelerometerEvent onto a
  // gravity unit vector from a separate accelerometerEventStream. This was
  // mathematically wrong — projecting a gravity-free vector onto a gravity
  // axis produces noise, not a meaningful forward component.
  //
  // Correct approach: UserAccelerometerEvent already has gravity removed by
  // the OS sensor fusion. For a phone held upright in-hand while walking:
  //   • e.z  ≈ forward/backward (+z = forward, screen facing user)
  //   • e.x  ≈ lateral (left/right)
  //
  // We average signed e.z over the cycle. Negative average → backward.
  // If |lateral| >> |forward| → side-step (half step length).
  // Default: FORWARD (overwhelmingly most common during navigation).

  double _computeDirection() {
    if (_forwardSampleCount == 0) {
      log('No direction samples, defaulting to FORWARD', name: 'PDR.DIR');
      return 1.0;
    }
    final avgFwd = _netForwardAccel / _forwardSampleCount;
    final avgLat = _netLateralAccel / _forwardSampleCount;
    log('avgZ(fwd)=${avgFwd.toStringAsFixed(3)} avgX(lat)=${avgLat.toStringAsFixed(3)} samples=$_forwardSampleCount', name: 'PDR.DIR');

    // Clear lateral dominance → side-step
    if (avgLat.abs() > avgFwd.abs() * 2.0) {
      log('→ LATERAL movement (half step)', name: 'PDR.DIR');
      return 0.5;
    }
    // Backward: needs stronger threshold (−0.5) to avoid noise misfires
    if (avgFwd < -0.5) {
      log('→ BACKWARD', name: 'PDR.DIR');
      return -1.0;
    }
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
