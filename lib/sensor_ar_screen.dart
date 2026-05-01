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

class SensorARScreen extends StatefulWidget {
  final MallData mall;
  final String startNodeId;
  final double initialFacingRadians;

  const SensorARScreen({
    super.key,
    required this.mall,
    required this.startNodeId,
    this.initialFacingRadians = 0.0,
  });

  @override
  State<SensorARScreen> createState() => _SensorARScreenState();
}

class _SensorARScreenState extends State<SensorARScreen> {
  CameraController? _cam;
  bool _isCamReady = false;

  late final NavGraph _graph;
  late PDRTracker _pdr;
  final IsolateLocalizer _localizer = IsolateLocalizer();
  CameraIntrinsics? _intrinsics;

  List<NavNode>? _path;
  int _wpIdx = 0;
  bool _isNav = false;
  bool _arrived = false;
  String _shop = '';
  Shop? _selectedShop; // also the active visual-localization target

  double _arrowAngle = 0;
  double _remainDist = 0;
  double _compassHead = 0;
  int _steps = 0;
  String _debugText = '';
  String _scanStatus = 'Tap shutter at a sign';
  Color _scanStatusColor = Colors.white;
  bool _scanning = false;
  int _corrections = 0;
  final double _arrTh = 1.5;
  bool _isMapExpanded = false;

  static const int _driftStepsThreshold = 20;

  @override
  void initState() {
    super.initState();
    log('initState: start=${widget.startNodeId} facing=${widget.initialFacingRadians}',
        name: 'SENSOR');

    _graph = widget.mall.navigationGraph;

    final sn = _graph.nodes[widget.startNodeId]!;
    log('Start node: ${sn.id} at ${sn.position}', name: 'SENSOR');

    _pdr = PDRTracker(
      startPosition: sn.position,
      initialMapFacingRadians: widget.initialFacingRadians,
    );
    _pdr.onPositionUpdate = _onPosUpdate;
    _pdr.onStepDetected = _onStep;
    _pdr.onHeadingUpdate = _onHeading;

    _initCam();
    _localizer.spawn();
    _requestLocationThenStartPdr();
  }

  // iOS CoreLocation will emit heading = -1 until the user grants
  // locationWhenInUse. The compass stream is started by _pdr.start(), so we
  // request permission first; if the user denies, we still start PDR (it
  // degrades gracefully to a constant heading with our invalid-reading filter).
  Future<void> _requestLocationThenStartPdr() async {
    try {
      final status = await Permission.locationWhenInUse.request();
      log('Location permission: $status', name: 'SENSOR');
    } catch (e) {
      log('Location permission request error: $e', name: 'SENSOR');
    }
    if (!mounted) return;
    _pdr.start();
  }

  @override
  void dispose() {
    _pdr.stop();
    _cam?.dispose();
    _localizer.dispose();
    super.dispose();
  }

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
    if (!_isNav || _path == null) return;

    if (_steps % 5 == 0 && _steps > 0) {
      log('Snap check at step $_steps', name: 'SENSOR');
      // Only consider nodes ahead on the path plus the one just passed
      // (edge-case backtrack). Passed waypoints would drag us back along
      // the route; unrelated graph nodes could pull us off entirely.
      final start = _wpIdx > 0 ? _wpIdx - 1 : 0;
      _pdr.snapToNodes(_path!.sublist(start));
    }

    if (_wpIdx < _path!.length) {
      final target = _path![_wpIdx];
      final dist = pos.distanceTo(target.position);
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
          _pdr.correctPosition(target.position);
          _pdr.resetWalkingState();
          setState(() {
            _arrived = true;
            _isNav = false;
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
          'Drift: ${_pdr.stepsSinceLastFix} steps since fix\n'
          'Heading: ${_compassHead.toStringAsFixed(0)}°\n'
          'Walking: ${_pdr.isWalkingDetected ? "LOCKED" : "detecting..."}\n'
          'Target: ${_wpIdx < _path!.length ? _path![_wpIdx].id : "arrived"}';
    });
  }

  void _onStep(int total) {
    setState(() => _steps = total);
  }

  void _onHeading(double h) {
    _compassHead = h;
    if (_isNav && _path != null) _updateArrow(_pdr.currentPosition);
  }

  // ── Arrow computation ──
  void _updateArrow(Vector3 uPos) {
    if (_path == null || _wpIdx >= _path!.length) return;
    final t = _path![_wpIdx].position;
    final dx = t.x - uPos.x, dz = t.z - uPos.z;
    final bearing = math.atan2(dz, dx);
    final compassRad = _compassHead * math.pi / 180.0;
    final arrow = bearing -
        (widget.initialFacingRadians +
            (compassRad - _pdr.initialHeading * math.pi / 180.0));

    double rem = uPos.distanceTo(t);
    for (int i = _wpIdx; i < _path!.length - 1; i++) {
      rem += _path![i].position.distanceTo(_path![i + 1].position);
    }
    setState(() {
      _arrowAngle = arrow;
      _remainDist = rem;
    });
  }

  // ── Navigation start ──
  void _onDestSelected(Shop shop) {
    log('Destination selected: "${shop.name}" (${shop.id})', name: 'SENSOR');
    _selectedShop = shop;
    // Phase 7.2 — manual fallback fix. If the user picks a shop they're
    // standing at, anchor PDR at its doorstep so navigation always
    // works even when no visual scan has succeeded.
    if (shop.id == widget.startNodeId ||
        _pdr.currentPosition.distanceTo(shop.doorstep) < 1.5) {
      _pdr.correctPosition(shop.doorstep);
      log('Manual position fix at "${shop.name}" doorstep ${shop.doorstep}',
          name: 'SENSOR');
    }

    // The shop's id may not match a graph node id directly. Find the
    // graph node that references this shop.
    NavNode? destNode;
    for (final n in _graph.nodes.values) {
      if (n.shopName == shop.name) {
        destNode = n;
        break;
      }
    }
    if (destNode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No graph node for "${shop.name}".'),
            backgroundColor: Colors.red),
      );
      return;
    }

    final nid = _graph.findNearestNode(_pdr.currentPosition);
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
      _isNav = true;
      _shop = shop.name;
      _arrived = false;
    });
    _updateArrow(_pdr.currentPosition);
  }

  // ── Visual scan ──
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
    final shop = _selectedShop;
    if (shop == null) {
      _setScanStatus('Pick a shop first to scan', Colors.orange);
      return;
    }

    setState(() {
      _scanning = true;
      _scanStatus = 'Scanning...';
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
        _pdr.correctPositionAndHeading(
          result.mallPosition!,
          result.mallHeadingDeg ?? geom.compassToMallHeading(_compassHead),
        );
        _corrections++;
        _setScanStatus(
          '✓ Fix at ${shop.name} (${result.inlierCount}/${result.goodMatchCount})',
          Colors.green,
        );
        if (_isNav && _path != null) _updateArrow(result.mallPosition!);
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
    return Scaffold(
      body: Stack(children: [
        _buildCam(),
        if (_isNav) _buildArrow(),
        _buildStatus(),
        _buildMiniMap(),
        _buildDebug(),
        _buildShutter(),
        if (!_isNav && !_arrived) _buildPicker(),
        if (_isNav) _buildNavInfo(),
        if (_arrived) _buildArrival(),
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
    final driftWarn =
        _pdr.stepsSinceLastFix > _driftStepsThreshold && _corrections > 0;
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
                  ? '⚠ ${_pdr.stepsSinceLastFix} steps since last fix — rescan'
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
        bottom: _isNav ? 200 : 280,
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

  // Shutter is anchored above the picker/nav-info bottom sheet.
  Widget _buildShutter() {
    final bottom = (_isNav || _arrived) ? 130.0 : 220.0;
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
                    color: _selectedShop == null ? Colors.grey : Colors.black,
                    size: 36,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildPicker() {
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
            Text('You are at: ${widget.startNodeId}',
                style: TextStyle(fontSize: 14, color: Colors.grey[600])),
            const SizedBox(height: 4),
            const Text('Where do you want to go?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.search),
                  label: Text(_selectedShop == null
                      ? 'Find a shop'
                      : 'Go to ${_selectedShop!.name}'),
                  onPressed: _openShopSearch,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.center_focus_strong,
                  size: 14, color: Colors.blue[700]),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _selectedShop == null
                      ? 'Pick a shop, then tap the shutter at its sign'
                      : 'Tap the shutter at the ${_selectedShop!.name} sign to lock position',
                  style: TextStyle(fontSize: 12, color: Colors.blue[700]),
                ),
              ),
            ]),
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
                    _isNav = false;
                    _path = null;
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
                    onPressed: () => setState(() => _arrived = false),
                    child: const Text('Navigate Somewhere Else'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildMiniMap() {
    final width = _isMapExpanded ? MediaQuery.of(context).size.width - 32 : 120.0;
    final height = _isMapExpanded ? MediaQuery.of(context).size.height * 0.4 : 160.0;
    final topRads = widget.initialFacingRadians +
        (_compassHead - _pdr.initialHeading) * math.pi / 180.0;

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
                userPosition: _pdr.currentPosition,
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

  // ── Fuzzy shop search bottom sheet (Phase 2.7) ───────────────

  void _openShopSearch() async {
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
