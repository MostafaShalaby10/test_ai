import 'dart:developer';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'ar_navigation_system.dart';

class ARNavigationScreen extends StatefulWidget {
  final Map<String, dynamic> mallJson;
  final String startNodeId;
  const ARNavigationScreen({super.key, required this.mallJson, required this.startNodeId});
  @override
  State<ARNavigationScreen> createState() => _ARNavigationScreenState();
}

class _ARNavigationScreenState extends State<ARNavigationScreen> {
  late ARSessionManager arSessionManager;
  late ARObjectManager arObjectManager;
  late NavigationSession _session;

  bool _isARReady = false;
  bool _isNavigating = false;
  bool _hasArrived = false;
  String _debugText = '';
  double _remainingDistance = 0;
  String _selectedShop = '';

  @override
  void initState() {
    super.initState();
    log('initState: mallJson nodes=${(widget.mallJson["nodes"] as List).length} startNode=${widget.startNodeId}', name: 'AR');
    final graph = NavGraph.fromJson(widget.mallJson);
    _session = NavigationSession(graph: graph);
    _session.avatar.onAvatarMoved = _onAvatarMoved;
    _session.avatar.onArrived = _onArrived;
    _session.avatar.onDistanceUpdate = _onDistanceUpdate;
  }

  @override
  void dispose() { arSessionManager.dispose(); super.dispose(); }

  void _alignFromInitialPosition(Vector3 firstARPos) {
    final startNode = _session.graph.nodes[widget.startNodeId];
    if (startNode == null) { log('ERROR: startNode "${widget.startNodeId}" not found!', name: 'AR'); return; }
    _session.aligner.alignFromQRCode(knownMapPosition: startNode.position, arDetectedPosition: firstARPos);
    log('Aligned: AR $firstARPos → map ${startNode.position}', name: 'AR');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      ARView(onARViewCreated: _onARViewCreated, planeDetectionConfig: PlaneDetectionConfig.horizontal),
      _buildStatusBar(),
      _buildDebugOverlay(),
      if (_isARReady && !_isNavigating && !_hasArrived) _buildDestinationPicker(),
      if (_isNavigating) _buildNavigationInfo(),
      if (_hasArrived) _buildArrivalOverlay(),
    ]));
  }

  void _onARViewCreated(ARSessionManager sm, ARObjectManager om, ARAnchorManager am, ARLocationManager lm) {
    arSessionManager = sm; arObjectManager = om;
    arSessionManager.onInitialize(showFeaturePoints: false, showPlanes: false, showWorldOrigin: true, handleTaps: false);
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
            _alignFromInitialPosition(arPos);
            setState(() => _isARReady = true);
            log('★ AR tracking started. First pose: $arPos', name: 'AR');
          }
          final avatarARPos = _session.onARFrameUpdate(arPos);
          if (avatarARPos != null) _updateAvatarModel(avatarARPos);
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
