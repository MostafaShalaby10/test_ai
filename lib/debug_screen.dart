import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:path_provider/path_provider.dart';

import 'ar_navigation_system.dart';
import 'camera_intrinsics.dart';
import 'localization_service.dart';
import 'mall_data.dart';
import 'mall_geometry.dart' as geom;
import 'map_2d_screen.dart' show MapPainter;
import 'pdr_tracker.dart';

// ═══════════════════════════════════════════════════════════════
// DebugScreen — developer-only panel that shows everything the
// localization stack is producing in one place. Per the plan's
// Phase 0.4: walking around the mall watching the five fields agree
// is faster than reading logs.
//
// Reachable from the home screen via long-press on the title (gated
// on kDebugMode).
//
// Phase 3.3 will add a "self-test" button to this screen that runs
// the full ORB → solvePnP pipeline against bundled test images.
// ═══════════════════════════════════════════════════════════════

class LastSolvePnpSnapshot {
  final Vector3? signFramePos;
  final Vector3? mallFramePos;
  final double? headingDeg;
  final double? confidence;
  final int? inlierCount;
  final String? failReason;
  final DateTime at;

  LastSolvePnpSnapshot({
    this.signFramePos,
    this.mallFramePos,
    this.headingDeg,
    this.confidence,
    this.inlierCount,
    this.failReason,
    required this.at,
  });

  bool get isFailure => failReason != null;
}

class _SelfTestRow {
  final IconData icon;
  final Color color;
  final String message;
  const _SelfTestRow(this.icon, this.color, this.message);

  factory _SelfTestRow.pass(String msg) =>
      _SelfTestRow(Icons.check_circle, Colors.green, msg);
  factory _SelfTestRow.fail(String msg) =>
      _SelfTestRow(Icons.error, Colors.red, msg);
  factory _SelfTestRow.skipped(String msg) =>
      _SelfTestRow(Icons.remove_circle_outline, Colors.grey, msg);
}

// Simple module-level holder so other widgets (sensor_ar_screen) can
// publish the latest scan result without needing a state-management lib.
class DebugDataBus {
  static final DebugDataBus instance = DebugDataBus._();
  DebugDataBus._();

  final ValueNotifier<LastSolvePnpSnapshot?> lastScan = ValueNotifier(null);
  final ValueNotifier<double?> lastFrameLaplacian = ValueNotifier(null);
  final ValueNotifier<Vector3?> lastPdrStepVector = ValueNotifier(null);

  void publishScan(LastSolvePnpSnapshot s) => lastScan.value = s;
  void publishLaplacian(double v) => lastFrameLaplacian.value = v;
  void publishPdrStep(Vector3 stepDelta) => lastPdrStepVector.value = stepDelta;
}

class DebugScreen extends StatefulWidget {
  final MallData mall;
  final String startNodeId;
  const DebugScreen({super.key, required this.mall, required this.startNodeId});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  late PDRTracker _pdr;
  StreamSubscription<CompassEvent>? _compassSub;

  Vector3 _pos = const Vector3(0, 0, 0);
  Vector3? _lastStepDelta;
  double _compassRaw = double.nan;
  double? _compassAccuracy;
  int _steps = 0;

  // Self-test results: shop_id → human-readable line.
  final Map<String, _SelfTestRow> _selfTestResults = {};
  bool _selfTestRunning = false;

  // Ground-truth log (Phase 6.1).
  String? _groundTruthPath;
  int _groundTruthCount = 0;

  @override
  void initState() {
    super.initState();
    final start = widget.mall.navigationGraph.nodes[widget.startNodeId] ??
        widget.mall.navigationGraph.nodes.values.first;
    _pos = start.position;

    _pdr = PDRTracker(startPosition: start.position);
    _pdr.onPositionUpdate = (p) {
      setState(() {
        _lastStepDelta = p - _pos;
        _pos = p;
      });
      DebugDataBus.instance.publishPdrStep(_lastStepDelta!);
    };
    _pdr.onStepDetected = (n) => setState(() => _steps = n);
    _pdr.onHeadingUpdate = (_) => setState(() {}); // refresh heading display
    _pdr.start();

    _compassSub = FlutterCompass.events?.listen((e) {
      setState(() {
        _compassRaw = e.heading ?? double.nan;
        _compassAccuracy = e.accuracy;
      });
    });
  }

  @override
  void dispose() {
    _pdr.stop();
    _compassSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mallHead = _compassRaw.isNaN
        ? null
        : geom.compassToMallHeading(_compassRaw);
    final mallHeadRad = mallHead == null ? null : geom.degToRad(mallHead);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug — Visual Localization'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Map with position pin + heading arrow.
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.grey[100],
              child: CustomPaint(
                painter: MapPainter(
                  graph: widget.mall.navigationGraph,
                  userPosition: _pos,
                  userHeading: mallHeadRad,
                  userDotRadius: 8,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _section('Compass', [
                    _kv('raw', _compassRaw.isNaN
                        ? '—'
                        : '${_compassRaw.toStringAsFixed(1)}°'),
                    _kv('accuracy', _compassAccuracy?.toStringAsFixed(1) ?? '—'),
                    _kv('mall heading', mallHead == null
                        ? '—'
                        : '${mallHead.toStringAsFixed(1)}°'),
                    _kv('mallNorthOffset', '${geom.kMallNorthOffsetDeg}°  (TODO field-measure)'),
                  ]),
                  const SizedBox(height: 8),
                  _section('PDR', [
                    _kv('position', _pos.toString()),
                    _kv('total steps', '$_steps'),
                    _kv('last step Δ', _lastStepDelta?.toString() ?? '—'),
                    _kv('walking lock', _pdr.isWalkingDetected ? 'LOCKED' : 'detecting'),
                  ]),
                  const SizedBox(height: 8),
                  _solvePnpSection(),
                  const SizedBox(height: 8),
                  _section('Frame quality', [
                    ValueListenableBuilder<double?>(
                      valueListenable: DebugDataBus.instance.lastFrameLaplacian,
                      builder: (_, v, __) => _kv(
                        'last Laplacian variance',
                        v == null ? '—' : v.toStringAsFixed(1),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _selfTestSection(),
                  const SizedBox(height: 8),
                  _groundTruthSection(),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        icon: _selfTestRunning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.science),
                        label: Text(_selfTestRunning
                            ? 'Self-test running…'
                            : 'Run self-test'),
                        onPressed: _selfTestRunning ? null : _runSelfTest,
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.bug_report),
                        label: const Text('Log fix → ground truth'),
                        onPressed: _logGroundTruth,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Self-test (Phase 3.3) ─────────────────────────────────────

  Future<void> _runSelfTest() async {
    if (_selfTestRunning) return;
    setState(() {
      _selfTestRunning = true;
      _selfTestResults.clear();
    });
    final svc = LocalizationService();
    svc.warmup();
    try {
      for (final shop in widget.mall.shops.values) {
        if (shop.featureFile == null) {
          setState(() {
            _selfTestResults[shop.id] = _SelfTestRow.skipped('no featureFile');
          });
          continue;
        }
        final assetPath = 'assets/mall/test_images/${shop.id}.jpg';
        Uint8List? jpeg;
        try {
          final data = await rootBundle.load(assetPath);
          jpeg = data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
        } catch (_) {
          setState(() {
            _selfTestResults[shop.id] = _SelfTestRow.skipped('no test image');
          });
          continue;
        }

        try {
          final features = await widget.mall.loadFeaturesForShop(shop.id);
          final frame = svc.extractFeatures(jpeg);
          if (frame == null) {
            setState(() {
              _selfTestResults[shop.id] = _SelfTestRow.fail('decode failed');
            });
            continue;
          }
          // For self-test we don't have device intrinsics; estimate from
          // the test image dimensions assuming a 60° HFOV. Real on-device
          // intrinsics will be more accurate.
          final intr = CameraIntrinsics.estimatedFromFov(
            width: frame.width,
            height: frame.height,
          );
          final result = svc.matchAndLocalize(
            frame: frame,
            target: features,
            shopData: shop,
            intrinsics: intr,
          );
          frame.dispose();

          if (!result.isSuccess) {
            setState(() {
              _selfTestResults[shop.id] = _SelfTestRow.fail(
                  failReasonHumanMessage(result.failReason!));
            });
          } else {
            // Expected position: standing in front of the doorstep,
            // ~3m back along the corridor (roughly the surveyor's standard
            // capture distance). Without ground-truth tied to each test
            // image we just report the predicted position; tighter checks
            // need real per-image expected coords.
            final pred = result.mallPosition!;
            final dist = pred.distanceTo(shop.doorstep);
            setState(() {
              _selfTestResults[shop.id] = _SelfTestRow.pass(
                'pred=$pred Δdoorstep=${dist.toStringAsFixed(2)}m '
                'inliers=${result.inlierCount}/${result.goodMatchCount}',
              );
            });
          }
        } catch (e) {
          setState(() {
            _selfTestResults[shop.id] = _SelfTestRow.fail('error: $e');
          });
        }
      }
    } finally {
      svc.dispose();
      if (mounted) setState(() => _selfTestRunning = false);
    }
  }

  // ── Ground-truth log (Phase 6.1) ──────────────────────────────

  Future<void> _logGroundTruth() async {
    final last = DebugDataBus.instance.lastScan.value;
    if (last == null || last.isFailure) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No successful scan to log yet.'),
      ));
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/mall_nav_ground_truth.jsonl';
      final file = File(path);
      final entry = jsonEncode({
        'tap_time': DateTime.now().toIso8601String(),
        'predicted': {
          'mallX': last.mallFramePos?.x,
          'mallY': last.mallFramePos?.y,
          'mallZ': last.mallFramePos?.z,
          'headingDeg': last.headingDeg,
        },
        'sign_frame': {
          'x': last.signFramePos?.x,
          'y': last.signFramePos?.y,
          'z': last.signFramePos?.z,
        },
        'inliers': last.inlierCount,
        'confidence': last.confidence,
      });
      await file.writeAsString('$entry\n', mode: FileMode.append, flush: true);
      log('Ground truth appended → $path', name: 'DEBUG');
      setState(() {
        _groundTruthPath = path;
        _groundTruthCount++;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Logged. Total this session: $_groundTruthCount'),
        ));
      }
    } catch (e) {
      log('Ground truth log failed: $e', name: 'DEBUG');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Log failed: $e'),
        ));
      }
    }
  }

  Widget _groundTruthSection() {
    if (_groundTruthCount == 0 && _groundTruthPath == null) {
      return const SizedBox.shrink();
    }
    return _section('Ground truth log', [
      _kv('entries', '$_groundTruthCount this session'),
      _kv('path', _groundTruthPath ?? '—'),
    ]);
  }

  Widget _selfTestSection() {
    if (_selfTestResults.isEmpty && !_selfTestRunning) {
      return const SizedBox.shrink();
    }
    final rows = _selfTestResults.entries.toList();
    return _section(
      'Self-test (${rows.length} shops)',
      [
        for (final e in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(e.value.icon, size: 12, color: e.value.color),
                const SizedBox(width: 4),
                SizedBox(
                  width: 90,
                  child: Text(e.key,
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                ),
                Expanded(
                  child: Text(
                    e.value.message,
                    style: TextStyle(
                      fontSize: 11,
                      color: e.value.color,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _solvePnpSection() {
    return ValueListenableBuilder<LastSolvePnpSnapshot?>(
      valueListenable: DebugDataBus.instance.lastScan,
      builder: (_, s, __) {
        if (s == null) {
          return _section('Last solvePnP', [_kv('—', 'no scan yet')]);
        }
        final age = DateTime.now().difference(s.at).inSeconds;
        if (s.isFailure) {
          return _section('Last solvePnP (${age}s ago — FAIL)', [
            _kv('reason', s.failReason!),
            _kv('inliers', '${s.inlierCount ?? 0}'),
          ]);
        }
        return _section('Last solvePnP (${age}s ago)', [
          _kv('sign frame', s.signFramePos?.toString() ?? '—'),
          _kv('mall frame', s.mallFramePos?.toString() ?? '—'),
          _kv('heading', s.headingDeg == null
              ? '—'
              : '${s.headingDeg!.toStringAsFixed(1)}°'),
          _kv('confidence', s.confidence?.toStringAsFixed(2) ?? '—'),
          _kv('inliers', '${s.inlierCount ?? 0}'),
        ]);
      },
    );
  }

  Widget _section(String title, List<Widget> rows) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ...rows,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 140,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[700],
                      fontFamily: 'monospace')),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
