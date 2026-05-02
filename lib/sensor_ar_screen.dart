import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:fuzzy/fuzzy.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ar_navigation_system.dart';
import 'camera_intrinsics.dart';
import 'debug_screen.dart' show DebugDataBus, LastSolvePnpSnapshot;
import 'isolate_localizer.dart';
import 'localization_service.dart';
import 'mall_data.dart';
import 'mall_geometry.dart' as geom;
import 'map_2d_screen.dart';
import 'pdr_tracker.dart';

enum _NavPhase {
  pickingDestination,
  pickingStartingShop,
  scanning,
  navigating,
  arrived,
}

class SensorARScreen extends StatefulWidget {
  final MallData mall;

  const SensorARScreen({super.key, required this.mall});

  @override
  State<SensorARScreen> createState() => _SensorARScreenState();
}

class _SensorARScreenState extends State<SensorARScreen> {
  CameraController? _cam;
  bool _isCamReady = false;

  late final NavGraph _graph;
  PDRTracker? _pdr;
  final IsolateLocalizer _localizer = IsolateLocalizer();
  CameraIntrinsics? _intrinsics;

  _NavPhase _phase = _NavPhase.pickingDestination;
  Shop? _destination;
  Shop? _startingShop;

  List<NavNode>? _path;
  int _wpIdx = 0;
  String _shop = '';

  double _arrowAngle = 0;
  double _remainDist = 0;
  double _compassHead = 0;
  int _steps = 0;
  String _debugText = '';
  String _scanStatus = 'Pick destination to start';
  Color _scanStatusColor = Colors.blueGrey;
  bool _scanning = false;
  int _corrections = 0;
  final double _arrTh = 1.5;
  bool _isMapExpanded = false;

  static const int _driftStepsThreshold = 20;

  @override
  void initState() {
    super.initState();
    log('initState', name: 'SENSOR');
    _graph = widget.mall.navigationGraph;
    _initCam();
    _localizer.spawn();
    _requestLocationPermission();
  }

  // iOS CoreLocation emits heading = -1 until the user grants
  // locationWhenInUse. We request up-front; PDR is created later (after a
  // successful scan) and will start the compass stream then.
  Future<void> _requestLocationPermission() async {
    try {
      final status = await Permission.locationWhenInUse.request();
      log('Location permission: $status', name: 'SENSOR');
    } catch (e) {
      log('Location permission request error: $e', name: 'SENSOR');
    }
  }

  @override
  void dispose() {
    _pdr?.stop();
    _cam?.dispose();
    _localizer.dispose();
    super.dispose();
  }

  // Shops the user can tell the app "I'm standing here" — only those with
  // SSF1 feature files can be visually localized against.
  List<Shop> _scannableShops() => widget.mall.shops.values
      .where((s) => s.featureFile != null)
      .toList();

  Future<void> _initCam() async {
    log('Initializing camera...', name: 'SENSOR');
    final cams = await availableCameras();
    log('Available cameras: ${cams.length} → ${cams.map((c) => "${c.name}(${c.lensDirection})").join(", ")}',
        name: 'SENSOR');
    final back = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    _cam = CameraController(back, ResolutionPreset.high, enableAudio: false);
    await _cam!.initialize();
    log('Camera ready: ${_cam!.value.previewSize}', name: 'SENSOR');

    // Fetch intrinsics once. Preview dims report as portrait-rotated on
    // mobile (size.width = sensor height). Use the larger as width here
    // so the intrinsics match the captured photo's orientation.
    final size = _cam!.value.previewSize;
    if (size != null) {
      final pw = size.height.toInt();
      final ph = size.width.toInt();
      _intrinsics = await CameraIntrinsicsChannel.fetch(
        cameraId: back.name,
        previewWidth: pw,
        previewHeight: ph,
      );
      log('Intrinsics: $_intrinsics', name: 'SENSOR');
    }

    if (mounted) setState(() => _isCamReady = true);
  }

  // ── PDR callbacks ──
  void _onPosUpdate(Vector3 pos) {
    if (_phase != _NavPhase.navigating || _path == null) return;
    final pdr = _pdr;
    if (pdr == null) return;

    if (_steps % 5 == 0 && _steps > 0) {
      log('Snap check at step $_steps', name: 'SENSOR');
      // Only consider nodes ahead on the path plus the one just passed
      // (edge-case backtrack). Passed waypoints would drag us back along
      // the route; unrelated graph nodes could pull us off entirely.
      final start = _wpIdx > 0 ? _wpIdx - 1 : 0;
      pdr.snapToNodes(_path!.sublist(start));
    }

    if (_wpIdx < _path!.length) {
      final target = _path![_wpIdx];
      final dist = pos.distanceToXZ(target.position);
      log('Distance to wp "${target.id}": ${dist.toStringAsFixed(2)}m (threshold=$_arrTh)',
          name: 'SENSOR.NAV');

      if (dist < _arrTh) {
        log('✓ Reached waypoint "${target.id}"', name: 'SENSOR.NAV');
        _wpIdx++;
        if (_wpIdx >= _path!.length) {
          log('★ ARRIVED at destination "$_shop"!', name: 'SENSOR.NAV');
          // Anchor PDR exactly at the destination node so the next navigation
          // starts from a known clean position, and clear the walking-lock so
          // stray steps while the arrival dialog is visible don't drift us off.
          pdr.correctPosition(target.position);
          pdr.resetWalkingState();
          setState(() {
            _phase = _NavPhase.arrived;
          });
          return;
        }
        log('Next waypoint: "${_path![_wpIdx].id}" at ${_path![_wpIdx].position}',
            name: 'SENSOR.NAV');
      }
    }

    _updateArrow(pos);
    setState(() {
      _debugText =
          'Pos: (${pos.x.toStringAsFixed(1)}, ${pos.z.toStringAsFixed(1)})\n'
          'Steps: $_steps | Fixes: $_corrections\n'
          'Drift: ${pdr.stepsSinceLastFix} steps since fix\n'
          'Heading: ${_compassHead.toStringAsFixed(0)}°\n'
          'Walking: ${pdr.isWalkingDetected ? "LOCKED" : "detecting..."}\n'
          'Target: ${_wpIdx < _path!.length ? _path![_wpIdx].id : "arrived"}';
    });
  }

  void _onStep(int total) {
    setState(() => _steps = total);
  }

  void _onHeading(double h) {
    _compassHead = h;
    final pdr = _pdr;
    if (_phase == _NavPhase.navigating && _path != null && pdr != null) {
      _updateArrow(pdr.currentPosition);
    }
  }

  // ── Arrow computation ──
  void _updateArrow(Vector3 uPos) {
    final pdr = _pdr;
    if (_path == null || _wpIdx >= _path!.length || pdr == null) return;
    final t = _path![_wpIdx].position;
    final dx = t.x - uPos.x, dz = t.z - uPos.z;
    final bearing = math.atan2(dz, dx);
    final compassRad = _compassHead * math.pi / 180.0;
    // initialMapFacingRadians is 0 (PDR is created with default), so the
    // arrow is bearing minus (compass - pdr.initialHeading) in radians.
    final arrow = bearing - (compassRad - pdr.initialHeading * math.pi / 180.0);

    double rem = uPos.distanceToXZ(t);
    for (int i = _wpIdx; i < _path!.length - 1; i++) {
      rem += _path![i].position.distanceTo(_path![i + 1].position);
    }
    setState(() {
      _arrowAngle = arrow;
      _remainDist = rem;
    });
  }

  // ── Phase 1 → 2: destination picked ──
  void _onDestSelected(Shop shop) {
    log('Destination selected: "${shop.name}" (${shop.id})', name: 'SENSOR');
    setState(() {
      _destination = shop;
      _phase = _NavPhase.pickingStartingShop;
      _scanStatus = 'Pick the shop you are standing at';
      _scanStatusColor = Colors.blueGrey;
    });
  }

  // ── Phase 2 → 3: starting shop picked, transition to scanning ──
  void _onStartingShopSelected(Shop shop) {
    log('Starting shop: "${shop.name}" (${shop.id})', name: 'SENSOR');
    setState(() {
      _startingShop = shop;
      _phase = _NavPhase.scanning;
      _scanStatus = 'Stand at the ${shop.name} sign and tap shutter';
      _scanStatusColor = Colors.blue;
    });
  }

  // ── Phase 3 → 4: build the path and start PDR after a successful scan ──
  void _startNavigationFromScan(Shop startingShop, Vector3 mallPosition,
      double mallHeadingDeg) {
    final dest = _destination;
    if (dest == null) {
      log('No destination set!', name: 'SENSOR');
      return;
    }

    // Find the graph node corresponding to the destination shop. The shop's
    // id may not match a graph node id directly.
    NavNode? destNode;
    for (final n in _graph.nodes.values) {
      if (n.shopName == dest.name) {
        destNode = n;
        break;
      }
    }
    if (destNode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No graph node for "${dest.name}".'),
            backgroundColor: Colors.red),
      );
      return;
    }

    // Build the PDR now that we have a real position fix.
    final pdr = PDRTracker(startPosition: mallPosition);
    pdr.onPositionUpdate = _onPosUpdate;
    pdr.onStepDetected = _onStep;
    pdr.onHeadingUpdate = _onHeading;
    pdr.start();
    pdr.correctPositionAndHeading(mallPosition, mallHeadingDeg);
    _pdr = pdr;

    final nid = _graph.findNearestNode(mallPosition);
    final path = _graph.findPath(nid, destNode.id);
    if (path == null) {
      log('No path found!', name: 'SENSOR');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No path found.'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    log('Path: ${path.map((n) => n.id).join(" → ")}', name: 'SENSOR');
    setState(() {
      _path = path;
      _wpIdx = path.length > 1 ? 1 : 0;
      _phase = _NavPhase.navigating;
      _shop = dest.name;
    });
    _updateArrow(mallPosition);
  }

  // ── Visual scan ──
  // In `scanning` phase: localizes against the chosen starting shop and, on
  // success, builds the PDR and starts navigation.
  // In `navigating` phase: re-localizes to correct PDR drift; the scan
  // target is whichever scannable shop the user is currently at — we use
  // `_startingShop` as the default, but real re-scan UX is out of scope.
  Future<void> _onShutterPressed() async {
    if (_scanning) return;
    if (_cam == null || !_cam!.value.isInitialized) {
      _setScanStatus('Camera not ready', Colors.orange);
      return;
    }
    if (_intrinsics == null) {
      _setScanStatus('No camera intrinsics', Colors.orange);
      return;
    }
    final shop = _startingShop;
    if (shop == null) {
      _setScanStatus('Pick where you are first', Colors.orange);
      return;
    }

    setState(() {
      _scanning = true;
      _scanStatus = 'Scanning ${shop.name}...';
      _scanStatusColor = Colors.blue;
    });

    try {
      final pic = await _cam!.takePicture();
      final bytes = await File(pic.path).readAsBytes();

      final features = await widget.mall.loadFeaturesForShop(shop.id);
      final result = await _localizer.localize(
        jpegBytes: bytes,
        target: features,
        shopData: shop,
        intrinsics: _intrinsics!,
      );

      // Publish to debug bus regardless of outcome.
      DebugDataBus.instance.publishScan(LastSolvePnpSnapshot(
        signFramePos: result.signFramePos,
        mallFramePos: result.mallPosition,
        headingDeg: result.mallHeadingDeg,
        confidence: result.confidence,
        inlierCount: result.inlierCount,
        failReason: result.failReason?.name,
        at: DateTime.now(),
      ));

      if (!mounted) return;
      if (result.isSuccess) {
        final mallHeading = result.mallHeadingDeg ??
            geom.compassToMallHeading(_compassHead);
        _corrections++;
        if (_phase == _NavPhase.scanning) {
          // First scan — bootstrap PDR + path and transition to navigating.
          _startNavigationFromScan(shop, result.mallPosition!, mallHeading);
        } else {
          // Re-scan during navigation: just correct the existing PDR.
          _pdr?.correctPositionAndHeading(result.mallPosition!, mallHeading);
          if (_path != null) _updateArrow(result.mallPosition!);
        }
        _setScanStatus(
          '✓ Fix at ${shop.name} (${result.inlierCount}/${result.goodMatchCount})',
          Colors.green,
        );
      } else {
        final reason = result.failReason!;
        _setScanStatus('✗ ${failReasonHumanMessage(reason)}', Colors.red);
      }
    } catch (e, st) {
      log('Scan error: $e\n$st', name: 'SENSOR');
      if (mounted) _setScanStatus('Scan error: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _setScanStatus(String msg, Color color) {
    setState(() {
      _scanStatus = msg;
      _scanStatusColor = color;
    });
  }

  // ── BUILD ──
  @override
  Widget build(BuildContext context) {
    final showCamera = _phase == _NavPhase.scanning ||
        _phase == _NavPhase.navigating ||
        _phase == _NavPhase.arrived;
    final showArrow = _phase == _NavPhase.navigating;
    final showShutter = _phase == _NavPhase.scanning ||
        _phase == _NavPhase.navigating;
    final showMiniMap = _phase == _NavPhase.navigating;
    final showDestPicker = _phase == _NavPhase.pickingDestination;
    final showStartPicker = _phase == _NavPhase.pickingStartingShop;
    final showScanPrompt = _phase == _NavPhase.scanning;
    final showNavInfo = _phase == _NavPhase.navigating;
    final showArrival = _phase == _NavPhase.arrived;

    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: showCamera ? _buildCam() : const ColoredBox(color: Colors.black),
        ),
        if (showArrow) _buildArrow(),
        _buildStatus(),
        if (showMiniMap) _buildMiniMap(),
        _buildDebug(),
        if (showShutter) _buildShutter(),
        if (showDestPicker) _buildDestPicker(),
        if (showStartPicker) _buildStartingShopPicker(),
        if (showScanPrompt) _buildScanPrompt(),
        if (showNavInfo) _buildNavInfo(),
        if (showArrival) _buildArrival(),
      ]),
    );
  }

  Widget _buildCam() {
    if (!_isCamReady || _cam == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _cam!.value.previewSize!.height,
          height: _cam!.value.previewSize!.width,
          child: CameraPreview(_cam!),
        ),
      ),
    );
  }

  Widget _buildArrow() {
    final deg = (_arrowAngle * 180 / math.pi) % 360;
    String hint;
    if (deg > 315 || deg < 45) {
      hint = 'Go straight';
    } else if (deg >= 45 && deg < 135) {
      hint = 'Turn right';
    } else if (deg >= 135 && deg < 225) {
      hint = 'Turn around';
    } else {
      hint = 'Turn left';
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Transform.rotate(
          angle: -_arrowAngle,
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child:
                const Icon(Icons.navigation, color: Colors.white, size: 60),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            hint,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold),
          ),
        ),
      ]),
    );
  }

  Widget _buildStatus() {
    final pdr = _pdr;
    final driftWarn = pdr != null &&
        pdr.stepsSinceLastFix > _driftStepsThreshold &&
        _corrections > 0;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _scanStatusColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(_scanning ? Icons.hourglass_top : Icons.center_focus_strong,
              color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              driftWarn
                  ? '⚠ ${pdr.stepsSinceLastFix} steps since last fix — rescan'
                  : _scanStatus,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _corrections > 0 ? Colors.green : Colors.orange,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$_corrections',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
        ]),
      ),
    );
  }

  Widget _buildDebug() => Positioned(
        bottom: _phase == _NavPhase.navigating ? 200 : 280,
        left: 8,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            _debugText.isEmpty ? 'PDR: waiting...\nScan: idle' : _debugText,
            style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 11,
                fontFamily: 'monospace'),
          ),
        ),
      );

  // Shutter is only shown during scanning + navigating phases.
  Widget _buildShutter() {
    final bottom = _phase == _NavPhase.navigating ? 130.0 : 220.0;
    return Positioned(
      bottom: bottom,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _scanning ? null : _onShutterPressed,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _scanning ? Colors.grey : Colors.white,
              border: Border.all(color: Colors.black54, width: 4),
            ),
            child: _scanning
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : Icon(
                    Icons.center_focus_strong,
                    color: _startingShop == null ? Colors.grey : Colors.black,
                    size: 36,
                  ),
          ),
        ),
      ),
    );
  }

  // Phase 1 — destination picker.
  Widget _buildDestPicker() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Step 1 of 2',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            const Text('Where do you want to go?',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.search),
                label: const Text('Choose destination'),
                onPressed: _openDestinationSearch,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Phase 2 — starting-shop picker (filtered to shops with feature files).
  Widget _buildStartingShopPicker() {
    final scannable = _scannableShops();
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Step 2 of 2',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text('Going to ${_destination?.name ?? ''}',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 8),
            const Text('Which shop are you standing at?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (scannable.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'No surveyed shops found. Run sign_surveyor and '
                  'scripts/sync_mall_assets.sh.',
                  style: TextStyle(fontSize: 13, color: Colors.red[700]),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: scannable
                    .map(
                      (s) => ElevatedButton.icon(
                        icon: const Icon(Icons.store),
                        label: Text(s.name),
                        onPressed: () => _onStartingShopSelected(s),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _phase = _NavPhase.pickingDestination;
                _scanStatus = 'Pick destination to start';
                _scanStatusColor = Colors.blueGrey;
              }),
              child: const Text('← Change destination'),
            ),
          ],
        ),
      ),
    );
  }

  // Phase 3 — banner above the live camera while the user lines up the shot.
  Widget _buildScanPrompt() {
    final shop = _startingShop;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Going to ${_destination?.name ?? ''}',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 4),
            Text(
              shop == null
                  ? 'Pick where you are first'
                  : 'Point at the ${shop.name} sign and tap shutter',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _phase = _NavPhase.pickingStartingShop;
                _scanStatus = 'Pick the shop you are standing at';
                _scanStatusColor = Colors.blueGrey;
              }),
              child: const Text('← Change starting shop'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavInfo() => Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_remainDist.toStringAsFixed(0)}m',
                          style: const TextStyle(
                              fontSize: 32, fontWeight: FontWeight.bold)),
                      Text('to $_shop',
                          style: TextStyle(
                              fontSize: 16, color: Colors.grey[600])),
                    ]),
                const Spacer(),
                Column(children: [
                  Icon(Icons.gps_fixed,
                      color: _corrections > 0 ? Colors.green : Colors.grey,
                      size: 20),
                  Text('$_corrections fixes',
                      style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                ]),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => setState(() {
                    _phase = _NavPhase.pickingDestination;
                    _path = null;
                    _destination = null;
                    _startingShop = null;
                    _pdr?.stop();
                    _pdr = null;
                    _scanStatus = 'Pick destination to start';
                    _scanStatusColor = Colors.blueGrey;
                  }),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.red)),
                ),
              ]),
              if (_corrections == 0 && _steps > 10)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Tip: Aim shutter at a shop sign for a precise fix',
                    style: TextStyle(fontSize: 11, color: Colors.orange[600]),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _buildArrival() => Positioned.fill(
        child: Container(
          color: Colors.black54,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(32),
              margin: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle,
                      color: Colors.green, size: 80),
                  const SizedBox(height: 16),
                  const Text('You Have Arrived!',
                      style: TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold)),
                  Text(_shop,
                      style:
                          TextStyle(fontSize: 18, color: Colors.grey[600])),
                  Text('$_steps steps · $_corrections fixes',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey[400])),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => setState(() {
                      _phase = _NavPhase.pickingDestination;
                      _destination = null;
                      _startingShop = null;
                      _path = null;
                      _pdr?.stop();
                      _pdr = null;
                      _scanStatus = 'Pick destination to start';
                      _scanStatusColor = Colors.blueGrey;
                    }),
                    child: const Text('Navigate Somewhere Else'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildMiniMap() {
    final pdr = _pdr;
    if (pdr == null) return const SizedBox.shrink();
    final width = _isMapExpanded ? MediaQuery.of(context).size.width - 32 : 120.0;
    final height = _isMapExpanded ? MediaQuery.of(context).size.height * 0.4 : 160.0;
    final topRads = (_compassHead - pdr.initialHeading) * math.pi / 180.0;

    return Positioned(
      top: MediaQuery.of(context).padding.top + 65,
      right: 16,
      child: GestureDetector(
        onTap: () => setState(() => _isMapExpanded = !_isMapExpanded),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.blueAccent, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: CustomPaint(
              painter: MapPainter(
                graph: _graph,
                path: _path,
                currentWaypointIndex: _wpIdx,
                userPosition: pdr.currentPosition,
                userHeading: topRads,
                userDotRadius: _isMapExpanded ? 8 : 4,
                scaleFactor: 1.0,
                padding: _isMapExpanded ? null : 15.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Fuzzy destination search bottom sheet ──
  void _openDestinationSearch() async {
    // Destinations include all shops AND graph nodes that are bridged via
    // shopName (e.g., the dangling `n_window`). We expose nav nodes here so
    // the user can navigate to map-only destinations that have no scannable
    // sign yet.
    final shops = widget.mall.shops.values.toList();
    final picked = await showModalBottomSheet<Shop>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ShopSearchSheet(shops: shops),
    );
    if (picked != null) {
      _onDestSelected(picked);
    }
  }
}

class _ShopSearchSheet extends StatefulWidget {
  final List<Shop> shops;
  const _ShopSearchSheet({required this.shops});
  @override
  State<_ShopSearchSheet> createState() => _ShopSearchSheetState();
}

class _ShopSearchSheetState extends State<_ShopSearchSheet> {
  late final Fuzzy<Shop> _fuzzy;
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Index by name for now. When `shop.aliases` lands (plan's
    // future-proofing section), index those too.
    _fuzzy = Fuzzy<Shop>(
      widget.shops,
      options: FuzzyOptions(
        keys: [
          WeightedKey(name: 'name', getter: (s) => s.name, weight: 1.0),
        ],
        threshold: 0.5,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.isEmpty
        ? widget.shops
        : _fuzzy.search(_query).map((r) => r.item).toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        top: 16,
      ),
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Find a shop',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Type to search…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: results.length,
                itemBuilder: (_, i) {
                  final s = results[i];
                  return ListTile(
                    leading: const Icon(Icons.store),
                    title: Text(s.name),
                    subtitle: Text(
                        'doorstep: ${s.doorstep}, facing ${s.facingAngle.toStringAsFixed(0)}°'),
                    onTap: () => Navigator.pop(context, s),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
