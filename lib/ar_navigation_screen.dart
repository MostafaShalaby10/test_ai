// ══════════════════════════════════════════════════════════════════════════════
// ar_navigation_screen.dart
//
// AR Navigation Screen — Initial Position Mode (No QR Codes)
//
// Instead of scanning a QR code, the user tells the app where they are
// by selecting a starting node (e.g., "entrance", "door").
// When the AR session starts tracking, we assume:
//
//   AR origin (0, 0, 0) = the user's selected starting position on the map.
//
// This means:
//   offset = AR(0,0,0) - map(startPosition)
//   So: offset = -startPosition (negated)
//
// Example:
//   User says "I'm at the entrance" → entrance is at map (0, 0, 5)
//   AR starts → camera is at AR (0, 0, 0)
//   offset = (0,0,0) - (0,0,5) = (0, 0, -5)
//   Later, AR says camera is at (3, 0, 0)
//   Map position = (3, 0, 0) - (0, 0, -5) = (3, 0, 5) ✓
//
// Flow:
//   1. Screen opens with a starting node ID → AR session starts
//   2. AR begins tracking → coordinates auto-align → destination picker shows
//   3. User taps a shop → path is computed, avatar guides them
//   4. User arrives → celebration UI
// ══════════════════════════════════════════════════════════════════════════════

import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/widgets/ar_view.dart';
import 'package:flutter/material.dart';

// ── AR Plugin ──


// ── Vector math ──
import 'package:vector_math/vector_math_64.dart' as vm;

// ── Our navigation system ──
import 'ar_navigation_system.dart';

class ARNavigationScreen extends StatefulWidget {
  /// The mall map JSON data (nodes + edges).
  final Map<String, dynamic> mallJson;

  /// The node ID where the user is starting from.
  /// Example: "entrance", "door", "parking_entrance"
  /// The AR session origin (0,0,0) will be mapped to this node's position.
  final String startNodeId;

  const ARNavigationScreen({
    super.key,
    required this.mallJson,
    required this.startNodeId,
  });

  @override
  State<ARNavigationScreen> createState() => _ARNavigationScreenState();
}

class _ARNavigationScreenState extends State<ARNavigationScreen> {
  // ── AR managers ──
  late ARSessionManager arSessionManager;
  late ARObjectManager arObjectManager;

  // ── Navigation system ──
  late NavigationSession _session;

  // ── State ──
  bool _isARReady = false;       // Has ARCore started tracking?
  bool _isNavigating = false;    // Is the avatar currently guiding?
  bool _hasArrived = false;      // Has the user reached the destination?
  String _debugText = '';        // Debug overlay text
  double _remainingDistance = 0; // Meters remaining to destination
  String _selectedShop = '';     // Name of the destination shop

  @override
  void initState() {
    super.initState();

    // Build the navigation graph from the mall JSON.
    final graph = NavGraph.fromJson(widget.mallJson);

    // Create the navigation session.
    _session = NavigationSession(graph: graph);

    // Set up avatar callbacks.
    _session.avatar.onAvatarMoved = _onAvatarMoved;
    _session.avatar.onArrived = _onArrived;
    _session.avatar.onDistanceUpdate = _onDistanceUpdate;
  }

  @override
  void dispose() {
    arSessionManager.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════
  // COORDINATE ALIGNMENT (No QR — uses initial position)
  //
  // When AR starts, the camera is at AR (0, 0, 0).
  // We know the user is at map position (startNode.x, startNode.y, startNode.z).
  // So the offset between the two systems is simply:
  //   offset = AR(0,0,0) - mapPosition = -mapPosition
  //
  // This alignment happens ONCE, automatically, when ARCore is ready.
  // ══════════════════════════════════════════════

  /// Aligns coordinate systems using the known starting position.
  /// Called once when ARCore provides the first valid camera pose.
  void _alignFromInitialPosition(Vector3 firstARPosition) {
    // Look up the starting node's map position.
    final startNode = _session.graph.nodes[widget.startNodeId];
    if (startNode == null) {
      print('[Align] ERROR: Start node "${widget.startNodeId}" not found!');
      return;
    }

    // Align: the AR position right now corresponds to this map position.
    _session.aligner.alignFromQRCode(
      knownMapPosition: startNode.position,
      arDetectedPosition: firstARPosition,
    );

    print('[Align] Aligned! AR origin → "${widget.startNodeId}" '
        'at ${startNode.position}');
  }

  // ══════════════════════════════════════════════
  // BUILD — Main UI layout
  // ══════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: AR camera view (full screen)
          _buildARView(),

          // Layer 2: Status bar at the top
          _buildStatusBar(),

          // Layer 3: Debug info overlay (bottom-left)
          _buildDebugOverlay(),

          // Layer 4: Destination picker (after AR is ready)
          if (_isARReady && !_isNavigating && !_hasArrived)
            _buildDestinationPicker(),

          // Layer 5: Navigation info (during navigation)
          if (_isNavigating) _buildNavigationInfo(),

          // Layer 6: Arrival celebration
          if (_hasArrived) _buildArrivalOverlay(),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════
  // AR VIEW
  // ══════════════════════════════════════════════

  Widget _buildARView() {
    return ARView(
      onARViewCreated: _onARViewCreated,
      planeDetectionConfig: PlaneDetectionConfig.horizontal,
    );
  }

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    arSessionManager = sessionManager;
    arObjectManager = objectManager;

    arSessionManager.onInitialize(
      showFeaturePoints: false,
      showPlanes: false,
      showWorldOrigin: true,
      handleTaps: false,
    );

    // Wait 2 seconds for ARCore to warm up, then start tracking.
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startFrameUpdates();
    });
  }

  // ══════════════════════════════════════════════
  // FRAME UPDATE LOOP — Runs every ~33ms (30fps)
  // ══════════════════════════════════════════════

  void _startFrameUpdates() {
    Future.delayed(const Duration(milliseconds: 33), () async {
      if (!mounted) return;

      try {
        final cameraPose = await arSessionManager.getCameraPose();

        if (cameraPose != null) {
          // Extract position from the 4x4 transform matrix.
          final arPos = Vector3(
            cameraPose.getColumn(3).x,
            cameraPose.getColumn(3).y,
            cameraPose.getColumn(3).z,
          );

          // ── First successful pose → auto-align and mark ready ──
          if (!_isARReady) {
            _alignFromInitialPosition(arPos);

            setState(() {
              _isARReady = true;
            });

            print('[AR] Tracking started. You are at "${widget.startNodeId}".');
          }

          // ── Update navigation ──
          final avatarARPos = _session.onARFrameUpdate(arPos);

          if (avatarARPos != null) {
            _updateAvatarModel(avatarARPos);
          }

          // ── Update debug overlay ──
          if (mounted) {
            setState(() {
              _debugText = _session.debugInfo;
            });
          }
        }
      } catch (e) {
        // ARCore not ready yet.
        if (mounted) {
          setState(() {
            _debugText = 'Waiting for AR tracking...\n'
                'Point camera at a textured surface.\n'
                'Start node: ${widget.startNodeId}';
          });
        }
      }

      _startFrameUpdates();
    });
  }

  // ══════════════════════════════════════════════
  // DESTINATION PICKER
  // ══════════════════════════════════════════════

  Widget _buildDestinationPicker() {
    final shops = _session.graph.nodes.values
        .where((node) =>
            node.shopName != null && node.id != widget.startNodeId)
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
            Text(
              'You are at: ${widget.startNodeId}',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            const SizedBox(height: 4),
            const Text(
              'Where do you want to go?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
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

  void _onDestinationSelected(NavNode shop) async {
    final vm.Matrix4? cameraPose;
    try {
      cameraPose = await arSessionManager.getCameraPose();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AR tracking lost. Move phone slowly.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    if (cameraPose == null) return;

    final arPos = Vector3(
      cameraPose.getColumn(3).x,
      cameraPose.getColumn(3).y,
      cameraPose.getColumn(3).z,
    );

    final success = _session.navigateTo(shop.id, arPos);

    if (success) {
      setState(() {
        _isNavigating = true;
        _selectedShop = shop.shopName ?? shop.id;
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No path found to this destination.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ══════════════════════════════════════════════
  // 3D AVATAR
  // ══════════════════════════════════════════════

  void _updateAvatarModel(Vector3 arPosition) {
    // TODO: Place/move your 3D model here.
    //
    // final node = ARNode(
    //   type: NodeType.webGLB,
    //   uri: "assets/avatar.glb",
    //   scale: vm.Vector3(0.5, 0.5, 0.5),
    //   position: vm.Vector3(arPosition.x, arPosition.y, arPosition.z),
    // );
    // arObjectManager.addNode(node);
  }

  // ══════════════════════════════════════════════
  // CALLBACKS
  // ══════════════════════════════════════════════

  void _onAvatarMoved(NavNode nextWaypoint) {
    final arPos = _session.aligner.mapToAR(nextWaypoint.position);
    if (arPos != null) _updateAvatarModel(arPos);
  }

  void _onArrived() {
    setState(() {
      _hasArrived = true;
      _isNavigating = false;
    });
  }

  void _onDistanceUpdate(double distToNext, double totalRemaining) {
    setState(() {
      _remainingDistance = totalRemaining;
    });
  }

  // ══════════════════════════════════════════════
  // UI COMPONENTS
  // ══════════════════════════════════════════════

  Widget _buildStatusBar() {
    final statusText = !_isARReady
        ? '⏳ Initializing AR... move phone slowly'
        : _isNavigating
            ? '🚶 Navigating to $_selectedShop'
            : _hasArrived
                ? '🎉 You have arrived!'
                : '✅ Ready — pick a destination';

    final statusColor = !_isARReady
        ? Colors.grey
        : _isNavigating
            ? Colors.blue
            : Colors.green;

    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: statusColor.withOpacity(0.9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          statusText,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          textAlign: TextAlign.center,
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
          _debugText,
          style: const TextStyle(
            color: Colors.greenAccent,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
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
                Text(
                  '${_remainingDistance.toStringAsFixed(0)}m',
                  style: const TextStyle(
                      fontSize: 32, fontWeight: FontWeight.bold),
                ),
                Text(
                  'to $_selectedShop',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              ],
            ),
            const Spacer(),
            TextButton(
              onPressed: () {
                setState(() {
                  _isNavigating = false;
                  _session.avatar.state = NavigationState.waitingForAlignment;
                });
              },
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
                const Text(
                  'You Have Arrived!',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedShop,
                  style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _hasArrived = false;
                      _isNavigating = false;
                    });
                  },
                  child: const Text('Navigate Somewhere Else'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
