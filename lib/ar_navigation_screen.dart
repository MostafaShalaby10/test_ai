import 'dart:developer';
import 'dart:math' as math;
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'ar_navigation_system.dart';
import 'mall_data.dart';

class ARNavigationScreen extends StatefulWidget {
  final MallData mall;
  final String startNodeId;
  const ARNavigationScreen({super.key, required this.mall, required this.startNodeId});
  @override
  State<ARNavigationScreen> createState() => _ARNavigationScreenState();
}

class _ARNavigationScreenState extends State<ARNavigationScreen> {
  late ARSessionManager arSessionManager;
  late ARObjectManager arObjectManager;
  late final NavigationSession _session;

  bool _isARReady = false;
  bool _isNavigating = false;
  bool _hasArrived = false;
  String _debugText = '';
  double _remainingDistance = 0;
  String _selectedShop = '';
  // Screen-space rotation of the directional arrow, in radians.
  // 0 = target ahead, positive = target to the right, ±π = target behind.
  double _arrowRadians = 0;

  @override
  void initState() {
    super.initState();
    log('initState: nodes=${widget.mall.navigationGraph.nodes.length} startNode=${widget.startNodeId}', name: 'AR');
    _session = NavigationSession(graph: widget.mall.navigationGraph);
    _session.avatar.onAvatarMoved = _onAvatarMoved;
    _session.avatar.onArrived = _onArrived;
    _session.avatar.onDistanceUpdate = _onDistanceUpdate;
  }

  @override
  void dispose() { arSessionManager.dispose(); super.dispose(); }

  // Align the map frame to the AR frame using the camera's initial pose.
  // We assume the user starts facing along the map's +X axis from the start
  // node (same convention as Tier 2's `initialFacingRadians=0`). The camera's
  // horizontal forward direction in AR is extracted from -column 2 of the
  // pose matrix; the yaw that rotates map +X onto that direction becomes
  // the aligner's yaw offset.
  void _alignFromInitialPose(vm.Matrix4 firstPose) {
    final startNode = _session.graph.nodes[widget.startNodeId];
    if (startNode == null) { log('ERROR: startNode "${widget.startNodeId}" not found!', name: 'AR'); return; }
    final firstARPos = Vector3(firstPose.getColumn(3).x, firstPose.getColumn(3).y, firstPose.getColumn(3).z);
    final backCol = firstPose.getColumn(2); // camera +Z in world = camera-back
    // Camera forward horizontal = -(backCol.x, backCol.z). The angle that
    // rotates map +X (=(1,0,0)) onto this forward is atan2(-fZ, fX).
    final arCameraYaw = math.atan2(backCol.z, -backCol.x);
    _session.aligner.alignFromQRCode(
      knownMapPosition: startNode.position,
      arDetectedPosition: firstARPos,
      arCameraYaw: arCameraYaw,
      knownMapYaw: 0.0,
    );
    log('Aligned: AR $firstARPos → map ${startNode.position}, camYaw=${arCameraYaw.toStringAsFixed(3)} rad', name: 'AR');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      ARView(onARViewCreated: _onARViewCreated, planeDetectionConfig: PlaneDetectionConfig.horizontal),
      _buildStatusBar(),
      if (_isNavigating && !_hasArrived) _buildArrowOverlay(),
      _buildDebugOverlay(),
      if (_isARReady && !_isNavigating && !_hasArrived) _buildDestinationPicker(),
      if (_isNavigating) _buildNavigationInfo(),
      if (_hasArrived) _buildArrivalOverlay(),
    ]));
  }

  void _onARViewCreated(ARSessionManager sm, ARObjectManager om, ARAnchorManager am, ARLocationManager lm) {
    arSessionManager = sm; arObjectManager = om;
    arSessionManager.onInitialize(showFeaturePoints: false, showPlanes: false, showWorldOrigin: true, handleTaps: false);
    // ar_flutter_plugin_2 declares these as `late` non-nullable and then does
    // `if (field != null)` in its method-call handler, which triggers a
    // LateInitializationError every time ARKit sends the event. Assigning
    // no-op handlers initializes the fields. We don't consume plane data.
    arSessionManager.onPlaneDetected = (_) {};
    arSessionManager.onPlaneOrPointTap = (_) {};
    log('AR view created. Waiting 2s for ARCore warmup...', name: 'AR');
    Future.delayed(const Duration(seconds: 2), () { if (mounted) _startFrameUpdates(); });
  }

  void _startFrameUpdates() {
    Future.delayed(const Duration(milliseconds: 33), () async {
      if (!mounted) return;
      try {
        final pose = await arSessionManager.getCameraPose();
        if (pose != null) {
          final arPos = Vector3(pose.getColumn(3).x, pose.getColumn(3).y, pose.getColumn(3).z);
          if (!_isARReady) {
            _alignFromInitialPose(pose);
            setState(() => _isARReady = true);
            log('★ AR tracking started. First pose: $arPos', name: 'AR');
          }
          final avatarARPos = _session.onARFrameUpdate(arPos);
          if (avatarARPos != null) {
            _updateAvatarModel(avatarARPos);
            // Bearing from camera forward to target, using ARKit's camera
            // basis directly. Column 0 = camera-right in world; -column 2 =
            // camera-forward in world. We drop the Y component so the arrow
            // represents a horizontal turn cue regardless of phone pitch.
            final rightCol = pose.getColumn(0);
            final backCol = pose.getColumn(2);
            final dX = avatarARPos.x - arPos.x;
            final dZ = avatarARPos.z - arPos.z;
            final forwardComp = -(dX * backCol.x + dZ * backCol.z);
            final rightComp = dX * rightCol.x + dZ * rightCol.z;
            final targetBearing = math.atan2(rightComp, forwardComp);
            // Low-pass filter toward the target bearing using the shortest
            // angular path. Without this, waypoint advances and sensor noise
            // cause the arrow to snap/stutter. 0.2 factor = ~150 ms settle.
            double delta = targetBearing - _arrowRadians;
            while (delta > math.pi) delta -= 2 * math.pi;
            while (delta < -math.pi) delta += 2 * math.pi;
            _arrowRadians += delta * 0.2;
          }
          if (mounted) setState(() { _debugText = _session.debugInfo; });
        }
      } catch (e) {
        if (mounted) setState(() { _debugText = 'Waiting for AR...\n${e.toString().split(",").first}'; });
      }
      _startFrameUpdates();
    });
  }

  void _onDestinationSelected(NavNode shop) async {
    log('Destination selected: ${shop.id} "${shop.shopName}"', name: 'AR');
    final vm.Matrix4? pose;
    try { pose = await arSessionManager.getCameraPose(); } catch (e) {
      log('Cannot get pose for navigation: $e', name: 'AR');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AR tracking lost.'), backgroundColor: Colors.orange));
      return;
    }
    if (pose == null) return;
    final arPos = Vector3(pose.getColumn(3).x, pose.getColumn(3).y, pose.getColumn(3).z);
    final success = _session.navigateTo(shop.id, arPos);
    log('navigateTo result: $success', name: 'AR');
    if (success) { setState(() { _isNavigating = true; _selectedShop = shop.shopName ?? shop.id; }); }
    else if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No path found.'), backgroundColor: Colors.red));
  }

  void _updateAvatarModel(Vector3 arPos) {
    // TODO: Place 3D model at arPos
  }

  void _onAvatarMoved(NavNode wp) {
    log('Avatar moved to: ${wp.id} ${wp.position}', name: 'AR');
    final arPos = _session.aligner.mapToAR(wp.position);
    if (arPos != null) _updateAvatarModel(arPos);
  }

  void _onArrived() { log('★ ARRIVED!', name: 'AR'); setState(() { _hasArrived = true; _isNavigating = false; }); }
  void _onDistanceUpdate(double d, double t) { setState(() { _remainingDistance = t; }); }

  // ── UI ──
  Widget _buildStatusBar() => Positioned(top: MediaQuery.of(context).padding.top + 8, left: 16, right: 16,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: (!_isARReady ? Colors.grey : _isNavigating ? Colors.blue : Colors.green).withOpacity(0.9), borderRadius: BorderRadius.circular(12)),
      child: Text(!_isARReady ? '⏳ Initializing AR...' : _isNavigating ? '🚶 Navigating to $_selectedShop' : '✅ Ready — pick a destination',
        style: const TextStyle(color: Colors.white, fontSize: 16), textAlign: TextAlign.center)));

  Widget _buildArrowOverlay() {
    final deg = ((_arrowRadians * 180 / math.pi) % 360 + 360) % 360;
    // "Go straight" only when the bearing is tightly aligned (±20°). The
    // previous ±45° window labelled mid-turn states as "Go straight" before
    // the user had actually finished turning.
    String hint;
    if (deg > 340 || deg < 20) {
      hint = 'Go straight';
    } else if (deg >= 20 && deg < 160) {
      hint = 'Turn right';
    } else if (deg >= 160 && deg < 200) {
      hint = 'Turn around';
    } else {
      hint = 'Turn left';
    }
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Transform.rotate(
        angle: _arrowRadians,
        child: Container(
          width: 100, height: 100,
          decoration: BoxDecoration(color: Colors.blue.withOpacity(0.7), shape: BoxShape.circle),
          child: const Icon(Icons.navigation, color: Colors.white, size: 60),
        ),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
        child: Text(hint, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      ),
    ]));
  }

  Widget _buildDebugOverlay() => Positioned(bottom: _isNavigating ? 120 : 200, left: 8,
    child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Text(_debugText, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'))));

  Widget _buildDestinationPicker() {
    final shops = _session.graph.nodes.values.where((n) => n.shopName != null && n.id != widget.startNodeId).toList();
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)]),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('You are at: ${widget.startNodeId}', style: TextStyle(fontSize: 14, color: Colors.grey[600])),
        const SizedBox(height: 4), const Text('Where do you want to go?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: shops.map((s) => ElevatedButton.icon(icon: const Icon(Icons.store), label: Text(s.shopName!), onPressed: () => _onDestinationSelected(s))).toList()),
      ])));
  }

  Widget _buildNavigationInfo() => Positioned(bottom: 0, left: 0, right: 0,
    child: Container(padding: const EdgeInsets.all(20), decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${_remainingDistance.toStringAsFixed(0)}m', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          Text('to $_selectedShop', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
        ]),
        const Spacer(),
        TextButton(onPressed: () => setState(() { _isNavigating = false; _session.avatar.state = NavigationState.waitingForAlignment; }), child: const Text('Cancel', style: TextStyle(color: Colors.red))),
      ])));

  Widget _buildArrivalOverlay() => Positioned.fill(child: Container(color: Colors.black54, child: Center(child: Container(
    padding: const EdgeInsets.all(32), margin: const EdgeInsets.all(40), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle, color: Colors.green, size: 80), const SizedBox(height: 16),
      const Text('You Have Arrived!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      Text(_selectedShop, style: TextStyle(fontSize: 18, color: Colors.grey[600])), const SizedBox(height: 24),
      ElevatedButton(onPressed: () => setState(() { _hasArrived = false; _isNavigating = false; }), child: const Text('Navigate Somewhere Else')),
    ])))));
}
