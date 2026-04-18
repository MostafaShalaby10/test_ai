import 'dart:math'as math;
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'ar_navigation_system.dart';
import 'pdr_tracker.dart';
import 'mindar_detector.dart';
import 'image_marker_registry.dart';
import 'map_2d_screen.dart';

class SensorARScreen extends StatefulWidget {
  final Map<String, dynamic> mallJson;
  final String startNodeId;
  final String mindFileUrl;
  final List<Map<String, dynamic>> imageMarkers;
  final double initialFacingRadians;

  const SensorARScreen({super.key, required this.mallJson, required this.startNodeId, required this.mindFileUrl, required this.imageMarkers, this.initialFacingRadians = 0.0});
  @override
  State<SensorARScreen> createState() => _SensorARScreenState();
}

class _SensorARScreenState extends State<SensorARScreen> {
  CameraController? _cam;
  bool _isCamReady = false;

  late NavGraph _graph;
  late PDRTracker _pdr;
  late ImageMarkerRegistry _markerReg;
  List<NavNode>? _path;
  int _wpIdx = 0;
  bool _isNav = false;
  bool _arrived = false;
  String _shop = '';

  double _arrowAngle = 0;
  double _remainDist = 0;
  double _compassHead = 0;
  int _steps = 0;
  String _debugText = '';
  String _markerStatus = 'Scanning...';
  int _corrections = 0;
  final double _arrTh = 1.5;
  bool _isMapExpanded = false;

  @override
  void initState() {
    super.initState();
    log('initState: start=${widget.startNodeId} mindFile=${widget.mindFileUrl} markers=${widget.imageMarkers.length} facing=${widget.initialFacingRadians}', name: 'SENSOR');

    _graph = NavGraph.fromJson(widget.mallJson);
    _markerReg = ImageMarkerRegistry();
    _markerReg.loadFromJson(widget.imageMarkers);

    final sn = _graph.nodes[widget.startNodeId]!;
    log('Start node: ${sn.id} at ${sn.position}', name: 'SENSOR');

    _pdr = PDRTracker(startPosition: sn.position, initialMapFacingRadians: widget.initialFacingRadians);
    _pdr.onPositionUpdate = _onPosUpdate;
    _pdr.onStepDetected = _onStep;
    _pdr.onHeadingUpdate = _onHeading;
    _pdr.onDebugUpdate = (d) { /* PDR internal debug available if needed */ };

    _initCam();
    _pdr.start();
  }

  @override
  void dispose() { _pdr.stop(); _cam?.dispose(); super.dispose(); }

  Future<void> _initCam() async {
    log('Initializing camera...', name: 'SENSOR');
    final cams = await availableCameras();
    log('Available cameras: ${cams.length} → ${cams.map((c) => "${c.name}(${c.lensDirection})").join(", ")}', name: 'SENSOR');
    final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
    _cam = CameraController(back, ResolutionPreset.medium, enableAudio: false);
    await _cam!.initialize();
    log('Camera ready: ${_cam!.value.previewSize}', name: 'SENSOR');
    if (mounted) setState(() => _isCamReady = true);
  }

  // ── MindAR callbacks ──
  void _onMarkerDetected(ImageMarker m) {
    log('★ MindAR CORRECTION: "${m.name}" idx=${m.targetIndex} pos=${m.position}', name: 'SENSOR');
    log('  PDR position BEFORE: ${_pdr.currentPosition}', name: 'SENSOR');
    _pdr.correctPosition(m.position);
    log('  PDR position AFTER: ${_pdr.currentPosition}', name: 'SENSOR');
    _corrections++;
    setState(() { _markerStatus = '✓ ${m.name} (#$_corrections)'; });
    if (_isNav && _path != null) _updateArrow(m.position);
  }

  void _onMarkerLost(int idx) {
    log('MindAR marker lost: idx=$idx', name: 'SENSOR');
    setState(() => _markerStatus = 'Scanning...');
  }

  // ── PDR callbacks ──
  void _onPosUpdate(Vector3 pos) {
    if (!_isNav || _path == null) return;

    if (_steps % 5 == 0 && _steps > 0) {
      log('Snap check at step $_steps', name: 'SENSOR');
      _pdr.snapToGraph(_graph);
    }

    if (_wpIdx < _path!.length) {
      final target = _path![_wpIdx];
      final dist = pos.distanceTo(target.position);
      log('Distance to wp "${target.id}": ${dist.toStringAsFixed(2)}m (threshold=$_arrTh)', name: 'SENSOR.NAV');

      if (dist < _arrTh) {
        log('✓ Reached waypoint "${target.id}"', name: 'SENSOR.NAV');
        _wpIdx++;
        if (_wpIdx >= _path!.length) {
          log('★ ARRIVED at destination "$_shop"!', name: 'SENSOR.NAV');
          setState(() { _arrived = true; _isNav = false; });
          return;
        }
        log('Next waypoint: "${_path![_wpIdx].id}" at ${_path![_wpIdx].position}', name: 'SENSOR.NAV');
      }
    }

    _updateArrow(pos);
    setState(() {
      _debugText = 'Pos: (${pos.x.toStringAsFixed(1)}, ${pos.z.toStringAsFixed(1)})\n'
          'Steps: $_steps | Corrections: $_corrections\n'
          'Heading: ${_compassHead.toStringAsFixed(0)}°\n'
          'Walking: ${_pdr.isWalkingDetected ? "LOCKED" : "detecting..."}\n'
          'Marker: $_markerStatus\n'
          'Target: ${_wpIdx < _path!.length ? _path![_wpIdx].id : "arrived"}';
    });
  }

  void _onStep(int total) {
    log('Step callback: total=$total', name: 'SENSOR');
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
    final arrow = bearing - (widget.initialFacingRadians + (compassRad - _pdr.initialHeading * math.pi / 180.0));

    double rem = uPos.distanceTo(t);
    for (int i = _wpIdx; i < _path!.length - 1; i++) rem += _path![i].position.distanceTo(_path![i + 1].position);
    setState(() { _arrowAngle = arrow; _remainDist = rem; });
  }

  // ── Navigation start ──
  void _onDestSelected(NavNode shop) {
    log('Destination selected: "${shop.shopName}" (${shop.id})', name: 'SENSOR');
    final nid = _graph.findNearestNode(_pdr.currentPosition);
    final path = _graph.findPath(nid, shop.id);
    if (path == null) {
      log('No path found!', name: 'SENSOR');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No path found.'), backgroundColor: Colors.red));
      return;
    }
    log('Path: ${path.map((n) => n.id).join(" → ")}', name: 'SENSOR');
    setState(() { _path = path; _wpIdx = 1; _isNav = true; _shop = shop.shopName ?? shop.id; _arrived = false; });
    _updateArrow(_pdr.currentPosition);
  }

  // ── BUILD ──
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      _buildCam(),
      MindARDetector(mindFileUrl: widget.mindFileUrl, registry: _markerReg, maxTrack: _markerReg.count.clamp(1, 5), onMarkerDetected: _onMarkerDetected, onMarkerLost: _onMarkerLost, showDebug: true, onError: (e) => log('MindAR error: $e', name: 'SENSOR')),
      if (_isNav) _buildArrow(),
      _buildStatus(),
      _buildMiniMap(),
      _buildDebug(),
      if (!_isNav && !_arrived) _buildPicker(),
      if (_isNav) _buildNavInfo(),
      if (_arrived) _buildArrival(),
    ]));
  }

  Widget _buildCam() {
    if (!_isCamReady || _cam == null) return const Center(child: CircularProgressIndicator());
    return SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: SizedBox(
      width: _cam!.value.previewSize!.height, height: _cam!.value.previewSize!.width, child: CameraPreview(_cam!))));
  }

  Widget _buildArrow() {
    final deg = (_arrowAngle * 180 / math.pi) % 360;
    String hint;
    if (deg > 315 || deg < 45) hint = 'Go straight';
    else if (deg >= 45 && deg < 135) hint = 'Turn right';
    else if (deg >= 135 && deg < 225) hint = 'Turn around';
    else hint = 'Turn left';
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Transform.rotate(angle: -_arrowAngle, child: Container(width: 100, height: 100, decoration: BoxDecoration(color: Colors.blue.withOpacity(0.7), shape: BoxShape.circle), child: const Icon(Icons.navigation, color: Colors.white, size: 60))),
      const SizedBox(height: 12),
      Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
        child: Text(hint, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
    ]));
  }

  Widget _buildStatus() => Positioned(top: MediaQuery.of(context).padding.top + 8, left: 16, right: 16,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: (_isNav ? Colors.blue : Colors.green).withOpacity(0.9), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.sensors, color: Colors.white, size: 18), const SizedBox(width: 8),
        Expanded(child: Text(_isNav ? '🚶 Navigating to $_shop' : '✅ Sensor AR + MindAR', style: const TextStyle(color: Colors.white, fontSize: 14))),
        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: _corrections > 0 ? Colors.green : Colors.orange, borderRadius: BorderRadius.circular(8)),
          child: Text('$_corrections', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
      ])));

  Widget _buildDebug() => Positioned(bottom: _isNav ? 120 : 200, left: 8,
    child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Text(_debugText.isEmpty ? 'PDR: waiting...\nMindAR: scanning...' : _debugText, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'))));

  Widget _buildPicker() {
    final shops = _graph.nodes.values.where((n) => n.shopName != null && n.id != widget.startNodeId).toList();
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)]),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('You are at: ${widget.startNodeId}', style: TextStyle(fontSize: 14, color: Colors.grey[600])),
        const SizedBox(height: 4), const Text('Where do you want to go?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4), Row(children: [Icon(Icons.sensors, size: 14, color: Colors.orange[700]), const SizedBox(width: 4), Text('PDR + MindAR', style: TextStyle(fontSize: 12, color: Colors.orange[700]))]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: shops.map((s) => ElevatedButton.icon(icon: const Icon(Icons.store), label: Text(s.shopName!), onPressed: () => _onDestSelected(s))).toList()),
      ])));
  }

  Widget _buildNavInfo() => Positioned(bottom: 0, left: 0, right: 0,
    child: Container(padding: const EdgeInsets.all(20), decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('${_remainDist.toStringAsFixed(0)}m', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
            Text('to $_shop', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
          ]),
          const Spacer(),
          Column(children: [Icon(Icons.gps_fixed, color: _corrections > 0 ? Colors.green : Colors.grey, size: 20), Text('$_corrections fixes', style: TextStyle(fontSize: 10, color: Colors.grey[500]))]),
          const SizedBox(width: 12),
          TextButton(onPressed: () => setState(() => _isNav = false), child: const Text('Cancel', style: TextStyle(color: Colors.red))),
        ]),
        if (_corrections == 0 && _steps > 10) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Tip: Point camera at mall signs for better accuracy', style: TextStyle(fontSize: 11, color: Colors.orange[600]))),
      ])));

  Widget _buildArrival() => Positioned.fill(child: Container(color: Colors.black54, child: Center(child: Container(
    padding: const EdgeInsets.all(32), margin: const EdgeInsets.all(40), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle, color: Colors.green, size: 80), const SizedBox(height: 16),
      const Text('You Have Arrived!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      Text(_shop, style: TextStyle(fontSize: 18, color: Colors.grey[600])),
      Text('$_steps steps · $_corrections marker corrections', style: TextStyle(fontSize: 12, color: Colors.grey[400])),
      const SizedBox(height: 24),
      ElevatedButton(onPressed: () => setState(() => _arrived = false), child: const Text('Navigate Somewhere Else')),
    ])))));

  Widget _buildMiniMap() {
    final width = _isMapExpanded ? MediaQuery.of(context).size.width - 32 : 120.0;
    final height = _isMapExpanded ? MediaQuery.of(context).size.height * 0.4 : 160.0;
    final topRads = widget.initialFacingRadians + (_compassHead - _pdr.initialHeading) * math.pi / 180.0;

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
            color: Colors.white.withOpacity(0.9),
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
}
