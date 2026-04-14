// ══════════════════════════════════════════════════════════════════════════════
// map_2d_screen.dart
//
// TIER 3: 2D Map Navigation
//
// For phones that don't support ARCore OR lack gyroscope/compass.
// Shows a top-down floor plan with:
//   - All nodes and edges drawn as a graph
//   - Shops labeled
//   - The computed path highlighted
//   - An animated dot showing where the user should be
//   - Turn-by-turn text directions
//
// The user manually taps "Next Step" to advance along the path
// (since we can't track their movement without sensors).
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:math';
import 'package:flutter/material.dart';

import 'ar_navigation_system.dart';

class Map2DScreen extends StatefulWidget {
  final Map<String, dynamic> mallJson;
  final String startNodeId;

  const Map2DScreen({
    super.key,
    required this.mallJson,
    required this.startNodeId,
  });

  @override
  State<Map2DScreen> createState() => _Map2DScreenState();
}

class _Map2DScreenState extends State<Map2DScreen>
    with SingleTickerProviderStateMixin {
  late NavGraph _graph;
  List<NavNode>? _path;
  int _currentWaypointIndex = 0;
  bool _isNavigating = false;
  bool _hasArrived = false;
  String _selectedShop = '';

  // Animation for the pulsing user dot.
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _graph = NavGraph.fromJson(widget.mallJson);

    // Pulsing animation for the user position dot.
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 8, end: 14).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _onDestinationSelected(NavNode shop) {
    final path = _graph.findPath(widget.startNodeId, shop.id);
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No path found.'), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() {
      _path = path;
      _currentWaypointIndex = 0;
      _isNavigating = true;
      _selectedShop = shop.shopName ?? shop.id;
      _hasArrived = false;
    });
  }

  void _advanceWaypoint() {
    if (_path == null) return;
    setState(() {
      _currentWaypointIndex++;
      if (_currentWaypointIndex >= _path!.length - 1) {
        _hasArrived = true;
        _isNavigating = false;
      }
    });
  }

  /// Generates a human-readable direction instruction between two nodes.
  String _getDirection(NavNode from, NavNode to) {
    final dx = to.position.x - from.position.x;
    final dz = to.position.z - from.position.z;
    final dy = to.position.y - from.position.y;
    final dist = from.position.distanceTo(to.position);

    // Handle floor changes.
    if (dy.abs() > 1.0) {
      return dy > 0
          ? 'Go UP to floor ${(to.position.y / 4.5).round()} (${dist.toStringAsFixed(0)}m)'
          : 'Go DOWN to floor ${(to.position.y / 4.5).round()} (${dist.toStringAsFixed(0)}m)';
    }

    // Compute direction name.
    final angle = atan2(dz, dx) * 180 / pi;
    String dir;
    if (angle > -22.5 && angle <= 22.5) {
      dir = 'right';
    } else if (angle > 22.5 && angle <= 67.5) {
      dir = 'forward-right';
    } else if (angle > 67.5 && angle <= 112.5) {
      dir = 'forward';
    } else if (angle > 112.5 && angle <= 157.5) {
      dir = 'forward-left';
    } else if (angle > 157.5 || angle <= -157.5) {
      dir = 'left';
    } else if (angle > -157.5 && angle <= -112.5) {
      dir = 'back-left';
    } else if (angle > -112.5 && angle <= -67.5) {
      dir = 'backward';
    } else {
      dir = 'back-right';
    }

    final targetName = to.shopName ?? to.id;
    return 'Walk $dir toward $targetName (${dist.toStringAsFixed(0)}m)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('2D Map Navigation'),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        actions: [
          if (_isNavigating)
            TextButton(
              onPressed: () => setState(() { _isNavigating = false; _path = null; }),
              child: const Text('Cancel', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Mode indicator ──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.orange[50],
            child: const Text(
              '📍 2D Map Mode — your device does not support AR',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),

          // ── Map view (takes most of the screen) ──
          Expanded(
            flex: 3,
            child: AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return CustomPaint(
                  painter: _MapPainter(
                    graph: _graph,
                    path: _path,
                    currentWaypointIndex: _currentWaypointIndex,
                    userDotRadius: _pulseAnimation.value,
                  ),
                  size: Size.infinite,
                );
              },
            ),
          ),

          // ── Bottom section: destination picker or directions ──
          if (!_isNavigating && !_hasArrived) _buildDestinationPicker(),
          if (_isNavigating) _buildDirections(),
          if (_hasArrived) _buildArrivalPanel(),
        ],
      ),
    );
  }

  Widget _buildDestinationPicker() {
    final shops = _graph.nodes.values
        .where((n) => n.shopName != null && n.id != widget.startNodeId)
        .toList();

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You are at: ${widget.startNodeId}',
              style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 8),
          const Text('Where do you want to go?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: shops.map((shop) {
              return ElevatedButton.icon(
                icon: const Icon(Icons.store),
                label: Text(shop.shopName!),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => _onDestinationSelected(shop),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDirections() {
    if (_path == null || _currentWaypointIndex >= _path!.length - 1) {
      return const SizedBox.shrink();
    }

    final current = _path![_currentWaypointIndex];
    final next = _path![_currentWaypointIndex + 1];
    final direction = _getDirection(current, next);
    final totalDist = _graph.pathDistance(
      _path!.sublist(_currentWaypointIndex),
    );

    // Build list of all remaining directions.
    final allDirections = <String>[];
    for (int i = _currentWaypointIndex; i < _path!.length - 1; i++) {
      allDirections.add(
        '${i - _currentWaypointIndex + 1}. ${_getDirection(_path![i], _path![i + 1])}',
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Current direction (big)
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.directions_walk, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(direction,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('${totalDist.toStringAsFixed(0)}m remaining to $_selectedShop',
                        style: TextStyle(color: Colors.grey[600])),
                    Text('Step ${_currentWaypointIndex + 1} of ${_path!.length - 1}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[400])),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // "I've reached this point" button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text("I'm here — next step"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _advanceWaypoint,
            ),
          ),

          // Upcoming directions (collapsed)
          if (allDirections.length > 1)
            ExpansionTile(
              title: const Text('All directions', style: TextStyle(fontSize: 14)),
              children: allDirections.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
                child: Text(d, style: const TextStyle(fontSize: 13)),
              )).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildArrivalPanel() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 60),
          const SizedBox(height: 12),
          const Text('You Have Arrived!',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(_selectedShop,
              style: TextStyle(fontSize: 16, color: Colors.grey[600])),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => setState(() { _hasArrived = false; _path = null; }),
            child: const Text('Navigate Somewhere Else'),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MAP PAINTER — Draws the 2D floor plan
//
// Renders:
//   - All edges as grey lines (the corridors)
//   - All nodes as small dots
//   - Shop nodes with labels
//   - The computed path as a thick colored line
//   - The user's current position as a pulsing blue dot
//   - The destination as a red marker
// ══════════════════════════════════════════════════════════════════════════════

class _MapPainter extends CustomPainter {
  final NavGraph graph;
  final List<NavNode>? path;
  final int currentWaypointIndex;
  final double userDotRadius;

  _MapPainter({
    required this.graph,
    this.path,
    this.currentWaypointIndex = 0,
    this.userDotRadius = 10,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Compute transform: map coordinates → screen pixels ──
    // Find the bounds of all nodes.
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minZ = double.infinity, maxZ = double.negativeInfinity;

    for (final node in graph.nodes.values) {
      minX = min(minX, node.position.x);
      maxX = max(maxX, node.position.x);
      minZ = min(minZ, node.position.z);
      maxZ = max(maxZ, node.position.z);
    }

    // Add padding.
    final padding = 40.0;
    final mapWidth = maxX - minX;
    final mapHeight = maxZ - minZ;

    // Scale to fit the screen.
    final scaleX = (size.width - padding * 2) / (mapWidth == 0 ? 1 : mapWidth);
    final scaleZ = (size.height - padding * 2) / (mapHeight == 0 ? 1 : mapHeight);
    final scale = min(scaleX, scaleZ);

    // Center the map.
    final offsetX = (size.width - mapWidth * scale) / 2;
    final offsetZ = (size.height - mapHeight * scale) / 2;

    // Convert map coordinates to screen coordinates.
    Offset toScreen(Vector3 pos) {
      return Offset(
        offsetX + (pos.x - minX) * scale,
        offsetZ + (pos.z - minZ) * scale,
      );
    }

    // ── Draw edges (corridors) ──
    final edgePaint = Paint()
      ..color = Colors.grey[300]!
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (final nodeId in graph.adjacency.keys) {
      final from = graph.nodes[nodeId]!;
      for (final neighbor in graph.adjacency[nodeId]!) {
        final to = graph.nodes[neighbor.neighborId]!;
        canvas.drawLine(toScreen(from.position), toScreen(to.position), edgePaint);
      }
    }

    // ── Draw path (highlighted route) ──
    if (path != null && path!.length > 1) {
      final pathPaint = Paint()
        ..color = Colors.orange
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      // Draw future path segments.
      for (int i = currentWaypointIndex; i < path!.length - 1; i++) {
        canvas.drawLine(
          toScreen(path![i].position),
          toScreen(path![i + 1].position),
          pathPaint,
        );
      }

      // Draw completed path segments (dimmer).
      final completedPaint = Paint()
        ..color = Colors.orange.withOpacity(0.3)
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke;

      for (int i = 0; i < currentWaypointIndex && i < path!.length - 1; i++) {
        canvas.drawLine(
          toScreen(path![i].position),
          toScreen(path![i + 1].position),
          completedPaint,
        );
      }

      // ── Draw destination marker ──
      final destPos = toScreen(path!.last.position);
      final destPaint = Paint()..color = Colors.red;
      canvas.drawCircle(destPos, 12, destPaint);
      canvas.drawCircle(destPos, 6, Paint()..color = Colors.white);
    }

    // ── Draw nodes ──
    final nodePaint = Paint()..color = Colors.grey[400]!;
    final shopPaint = Paint()..color = Colors.blue[700]!;
    final textStyle = TextStyle(fontSize: 10, color: Colors.grey[800]);
    final shopTextStyle = TextStyle(
      fontSize: 11,
      color: Colors.blue[900],
      fontWeight: FontWeight.bold,
    );

    for (final node in graph.nodes.values) {
      final pos = toScreen(node.position);
      final isShop = node.shopName != null;

      canvas.drawCircle(pos, isShop ? 6 : 3, isShop ? shopPaint : nodePaint);

      // Draw label for shops.
      if (isShop) {
        final textSpan = TextSpan(text: node.shopName, style: shopTextStyle);
        final tp = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy + 8));
      }
    }

    // ── Draw user position (pulsing dot) ──
    if (path != null && currentWaypointIndex < path!.length) {
      final userPos = toScreen(path![currentWaypointIndex].position);

      // Outer pulse.
      final pulsePaint = Paint()
        ..color = Colors.blue.withOpacity(0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(userPos, userDotRadius + 4, pulsePaint);

      // Inner solid dot.
      final userPaint = Paint()..color = Colors.blue;
      canvas.drawCircle(userPos, 8, userPaint);
      canvas.drawCircle(userPos, 4, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) {
    return old.currentWaypointIndex != currentWaypointIndex ||
        old.userDotRadius != userDotRadius ||
        old.path != path;
  }
}
