// ══════════════════════════════════════════════════════════════════════════════
// sensor_ar_screen.dart
//
// TIER 2: Sensor-Based AR Navigation
//
// For phones that have gyroscope + compass but NOT ARCore.
// Uses:
//   - Camera feed as background (raw camera, no AR tracking)
//   - Pedestrian Dead Reckoning (step counter + compass) for positioning
//   - 2D arrow overlay pointing toward the next waypoint
//   - Distance counter showing meters remaining
//
// It's not "true AR" (no 3D placement), but it gives the user a
// camera-based experience with directional guidance that feels AR-like.
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

import 'ar_navigation_system.dart';
import 'pdr_tracker.dart';

class SensorARScreen extends StatefulWidget {
  final Map<String, dynamic> mallJson;
  final String startNodeId;

  /// The direction the user is facing at the start node, in radians.
  /// 0 = facing +X direction, pi/2 = facing +Z direction.
  /// Set this based on where the user is looking when they open the app.
  final double initialFacingRadians;

  const SensorARScreen({
    super.key,
    required this.mallJson,
    required this.startNodeId,
    this.initialFacingRadians = 0.0,
  });

  @override
  State<SensorARScreen> createState() => _SensorARScreenState();
}

class _SensorARScreenState extends State<SensorARScreen> {
  // ── Camera ──
  CameraController? _cameraController;
  bool _isCameraReady = false;

  // ── Navigation ──
  late NavGraph _graph;
  late PDRTracker _pdr;
  List<NavNode>? _path;
  int _currentWaypointIndex = 0;
  bool _isNavigating = false;
  bool _hasArrived = false;
  String _selectedShop = '';

  // ── Display state ──
  double _arrowAngle = 0.0;   // Angle of the guidance arrow (radians)
  double _remainingDistance = 0;
  double _compassHeading = 0;
  int _stepCount = 0;
  String _debugText = '';
  final double _arrivalThreshold = 1.5; // Meters — more lenient than AR mode

  @override
  void initState() {
    super.initState();

    // Build navigation graph.
    _graph = NavGraph.fromJson(widget.mallJson);

    // Get start node position.
    final startNode = _graph.nodes[widget.startNodeId]!;

    // Create PDR tracker starting at the start node.
    _pdr = PDRTracker(
      startPosition: startNode.position,
      initialMapFacingRadians: widget.initialFacingRadians,
    );

    // Wire up PDR callbacks.
    _pdr.onPositionUpdate = _onPositionUpdate;
    _pdr.onStepDetected = _onStepDetected;
    _pdr.onHeadingUpdate = _onHeadingUpdate;

    // Initialize camera.
    _initCamera();

    // Start PDR tracking.
    _pdr.start();
  }

  @override
  void dispose() {
    _pdr.stop();
    _cameraController?.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════
  // CAMERA SETUP
  // ══════════════════════════════════════════════

  Future<void> _initCamera() async {
    // Get available cameras and pick the back camera.
    final cameras = await availableCameras();
    final backCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      backCamera,
      ResolutionPreset.medium, // Medium is enough — saves battery
      enableAudio: false,      // No mic needed
    );

    await _cameraController!.initialize();

    if (mounted) {
      setState(() {
        _isCameraReady = true;
      });
    }
  }

  // ══════════════════════════════════════════════
  // PDR CALLBACKS
  // ══════════════════════════════════════════════

  /// Called every time the user takes a step and position updates.
  void _onPositionUpdate(Vector3 position) {
    if (!_isNavigating || _path == null) return;

    // Snap to graph every 5 steps to correct drift.
    if (_stepCount % 5 == 0) {
      _pdr.snapToGraph(_graph);
    }

    // Check if user reached the current waypoint.
    if (_currentWaypointIndex < _path!.length) {
      final target = _path![_currentWaypointIndex];
      final dist = position.distanceTo(target.position);

      if (dist < _arrivalThreshold) {
        // Reached this waypoint — advance to next.
        _currentWaypointIndex++;

        if (_currentWaypointIndex >= _path!.length) {
          // Reached destination!
          setState(() {
            _hasArrived = true;
            _isNavigating = false;
          });
          return;
        }
      }
    }

    // Update arrow direction and distance.
    _updateArrow(position);

    // Update debug text.
    setState(() {
      _debugText = 'Pos: (${position.x.toStringAsFixed(1)}, '
          '${position.z.toStringAsFixed(1)})\n'
          'Steps: $_stepCount\n'
          'Heading: ${_compassHeading.toStringAsFixed(0)}°\n'
          'Target: ${_currentWaypointIndex < _path!.length ? _path![_currentWaypointIndex].id : "arrived"}';
    });
  }

  void _onStepDetected(int totalSteps) {
    setState(() {
      _stepCount = totalSteps;
    });
  }

  void _onHeadingUpdate(double headingDegrees) {
    _compassHeading = headingDegrees;

    // Recalculate arrow direction even between steps.
    if (_isNavigating && _path != null) {
      _updateArrow(_pdr.currentPosition);
    }
  }

  // ══════════════════════════════════════════════
  // ARROW DIRECTION COMPUTATION
  //
  // The arrow should point from the user toward the next waypoint.
  // But we need to show it RELATIVE to where the camera is pointing.
  //
  // Steps:
  //   1. Compute the bearing from user to next waypoint (map coordinates).
  //   2. Get the current compass heading (where the camera is pointing).
  //   3. Arrow angle = bearing - compass heading.
  //      If arrow points up (0°), the waypoint is straight ahead.
  //      If arrow points right (90°), turn right.
  // ══════════════════════════════════════════════

  void _updateArrow(Vector3 userPosition) {
    if (_currentWaypointIndex >= _path!.length) return;

    final target = _path![_currentWaypointIndex].position;

    // Compute bearing from user to target in map coordinates.
    // atan2(dz, dx) gives angle from +X axis.
    final dx = target.x - userPosition.x;
    final dz = target.z - userPosition.z;
    final bearingToTarget = atan2(dz, dx); // radians, map space

    // Convert compass heading to radians.
    // Compass: 0=N, 90=E, 180=S, 270=W
    // We need to map this to our map coordinate system.
    final compassRad = _compassHeading * pi / 180.0;

    // The arrow angle is the difference between where the target is
    // and where the phone is currently pointing in map space.
    // 0 = straight ahead, Positive = turn right, Negative = turn left.
    final arrowRad = bearingToTarget - _pdr.mapHeadingRadians;

    // Calculate remaining distance.
    double remaining = userPosition.distanceTo(target);
    for (int i = _currentWaypointIndex; i < _path!.length - 1; i++) {
      remaining += _path![i].position.distanceTo(_path![i + 1].position);
    }

    setState(() {
      _arrowAngle = arrowRad;
      _remainingDistance = remaining;
    });
  }

  // ══════════════════════════════════════════════
  // NAVIGATION START
  // ══════════════════════════════════════════════

  void _onDestinationSelected(NavNode shop) {
    final nearestId = _graph.findNearestNode(_pdr.currentPosition);
    final path = _graph.findPath(nearestId, shop.id);

    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No path found.'), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() {
      _path = path;
      _currentWaypointIndex = 1; // Skip start node (we're already there)
      _isNavigating = true;
      _selectedShop = shop.shopName ?? shop.id;
      _hasArrived = false;
    });

    _updateArrow(_pdr.currentPosition);
  }

  // ══════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Camera feed (full screen background)
          _buildCameraView(),

          // Layer 2: Direction arrow (center of screen)
          if (_isNavigating) _buildDirectionArrow(),

          // Layer 3: Status bar
          _buildStatusBar(),

          // Layer 4: Debug overlay
          _buildDebugOverlay(),

          // Layer 5: Destination picker
          if (!_isNavigating && !_hasArrived) _buildDestinationPicker(),

          // Layer 6: Navigation info
          if (_isNavigating) _buildNavigationInfo(),

          // Layer 7: Arrival
          if (_hasArrived) _buildArrivalOverlay(),

          // Layer 8: Mini-map (Top right)
          _buildMiniMap(),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════
  // UI WIDGETS
  // ══════════════════════════════════════════════

  Widget _buildCameraView() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Stretch the camera preview to fill the screen.
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _cameraController!.value.previewSize!.height,
          height: _cameraController!.value.previewSize!.width,
          child: CameraPreview(_cameraController!),
        ),
      ),
    );
  }

  /// The big arrow in the center of the screen that points toward
  /// the next waypoint. Rotates based on compass heading vs target bearing.
  Widget _buildDirectionArrow() {
    // Determine text hint based on arrow direction.
    final degrees = (_arrowAngle * 180 / pi) % 360;
    String hint;
    if (degrees > 315 || degrees < 45) {
      hint = 'Go straight';
    } else if (degrees >= 45 && degrees < 135) {
      hint = 'Turn right';
    } else if (degrees >= 135 && degrees < 225) {
      hint = 'Turn around';
    } else {
      hint = 'Turn left';
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rotating arrow
          Transform.rotate(
            angle: _arrowAngle, // Positive angle rotates clockwise
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.7),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.navigation,
                color: Colors.white,
                size: 60,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Direction hint text
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
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: (_isNavigating ? Colors.blue : Colors.green).withOpacity(0.9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.sensors, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              _isNavigating
                  ? '🚶 Navigating to $_selectedShop'
                  : '✅ Sensor AR — pick a destination',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugOverlay() {
    return Positioned(
      bottom: _isNavigating ? 120 : 200,
      left: 8,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _debugText.isEmpty ? 'Waiting for steps...' : _debugText,
          style: const TextStyle(
            color: Colors.greenAccent,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  Widget _buildDestinationPicker() {
    final shops = _graph.nodes.values
        .where((n) => n.shopName != null && n.id != widget.startNodeId)
        .toList();

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
            const SizedBox(height: 4),
            Text('Mode: Sensor AR (Compass + Step Counter)',
                style: TextStyle(fontSize: 12, color: Colors.orange[700])),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: shops.map((shop) {
                return ElevatedButton.icon(
                  icon: const Icon(Icons.store),
                  label: Text(shop.shopName!),
                  onPressed: () => _onDestinationSelected(shop),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationInfo() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_remainingDistance.toStringAsFixed(0)}m',
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                Text('to $_selectedShop',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                Text('$_stepCount steps taken',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400])),
              ],
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() { _isNavigating = false; }),
              child: const Text('Cancel', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArrivalOverlay() {
    return Positioned.fill(
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
                const Icon(Icons.check_circle, color: Colors.green, size: 80),
                const SizedBox(height: 16),
                const Text('You Have Arrived!',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                Text(_selectedShop,
                    style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                Text('$_stepCount steps',
                    style: TextStyle(fontSize: 14, color: Colors.grey[400])),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => setState(() {
                    _hasArrived = false;
                  }),
                  child: const Text('Navigate Somewhere Else'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniMap() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      right: 16,
      child: Container(
        width: 140,
        height: 140,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24, width: 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CustomPaint(
            painter: _MiniMapPainter(
              graph: _graph,
              userPosition: _pdr.currentPosition,
              path: _path,
              currentWaypointIndex: _currentWaypointIndex,
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MINI-MAP PAINTER
// ══════════════════════════════════════════════════════════════════════════════

class _MiniMapPainter extends CustomPainter {
  final NavGraph graph;
  final Vector3 userPosition;
  final List<NavNode>? path;
  final int currentWaypointIndex;

  _MiniMapPainter({
    required this.graph,
    required this.userPosition,
    this.path,
    this.currentWaypointIndex = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Compute transform (fixed scale) ──
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minZ = double.infinity, maxZ = double.negativeInfinity;

    for (final node in graph.nodes.values) {
      minX = min(minX, node.position.x);
      maxX = max(maxX, node.position.x);
      minZ = min(minZ, node.position.z);
      maxZ = max(maxZ, node.position.z);
    }

    final mapWidth = (maxX - minX).abs();
    final mapHeight = (maxZ - minZ).abs();
    final padding = 15.0;

    final scaleX = (size.width - padding * 2) / (mapWidth == 0 ? 1 : mapWidth);
    final scaleZ = (size.height - padding * 2) / (mapHeight == 0 ? 1 : mapHeight);
    final scale = min(scaleX, scaleZ);

    final offsetX = (size.width - mapWidth * scale) / 2;
    final offsetZ = (size.height - mapHeight * scale) / 2;

    Offset toScreen(Vector3 pos) {
      return Offset(
        offsetX + (pos.x - minX) * scale,
        offsetZ + (pos.z - minZ) * scale,
      );
    }

    // ── Draw edges ──
    final edgePaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..strokeWidth = 1.0;

    for (final nodeId in graph.adjacency.keys) {
      final from = graph.nodes[nodeId]!;
      for (final neighbor in graph.adjacency[nodeId]!) {
        final to = graph.nodes[neighbor.neighborId]!;
        canvas.drawLine(toScreen(from.position), toScreen(to.position), edgePaint);
      }
    }

    // ── Draw path ──
    if (path != null && path!.length > 1) {
      final pathPaint = Paint()
        ..color = Colors.orange.withOpacity(0.8)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      for (int i = max(0, currentWaypointIndex - 1); i < path!.length - 1; i++) {
        canvas.drawLine(
          toScreen(path![i].position),
          toScreen(path![i + 1].position),
          pathPaint,
        );
      }
    }

    // ── Draw nodes ──
    final nodePaint = Paint()..color = Colors.white38;
    for (final node in graph.nodes.values) {
      canvas.drawCircle(toScreen(node.position), 2, nodePaint);
    }

    // ── Draw user position ──
    final userPos = toScreen(userPosition);
    final userPaint = Paint()..color = Colors.blueAccent;
    canvas.drawCircle(userPos, 5, userPaint);
    canvas.drawCircle(userPos, 2.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter old) => true;
}
