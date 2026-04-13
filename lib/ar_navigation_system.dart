// ══════════════════════════════════════════════════════════════════════════════
// ar_navigation_system.dart
//
// Complete AR Navigation System for Indoor Mall Navigation.
// This file contains all the core logic needed to:
//   1. Scan a QR code to determine the user's starting position on the map.
//   2. Align the AR coordinate system with the mall map coordinate system.
//   3. Track the user's movement frame-by-frame using ARCore/ARKit.
//   4. Guide the user with a 3D avatar that moves along the computed path.
//
// Dependencies (add to pubspec.yaml):
//   ar_flutter_plugin: ^0.7.3
//   mobile_scanner: ^3.5.6
//   vector_math: ^2.1.4
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:math';

// ──────────────────────────────────────────────
// 1. Vector3 — 3D Point in Space (meters)
// ──────────────────────────────────────────────

/// Represents a 3D point using meters as the unit.
/// Used for both mall map coordinates and AR world coordinates.
class Vector3 {
  final double x, y, z;

  const Vector3(this.x, this.y, this.z);

  /// Straight-line distance between two points in 3D space.
  double distanceTo(Vector3 other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// Vector subtraction: used to calculate offsets between coordinate systems.
  Vector3 operator -(Vector3 other) =>
      Vector3(x - other.x, y - other.y, z - other.z);

  /// Vector addition: used to convert positions between coordinate systems.
  Vector3 operator +(Vector3 other) =>
      Vector3(x + other.x, y + other.y, z + other.z);

  factory Vector3.fromJson(Map<String, dynamic> json) => Vector3(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['z'] as num).toDouble(),
      );

  @override
  String toString() => '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})';
}

// ──────────────────────────────────────────────
// 2. NavNode & NavEdge — Mall Map Data
// ──────────────────────────────────────────────

class NavNode {
  final String id;
  final Vector3 position;
  final String? shopName;

  const NavNode({required this.id, required this.position, this.shopName});

  factory NavNode.fromJson(Map<String, dynamic> json) => NavNode(
        id: json['id'] as String,
        position: Vector3.fromJson(json),
        shopName: json['shopName'] as String?,
      );
}

class NavEdge {
  final String from;
  final String to;
  final bool oneway;
  final double weight;

  const NavEdge({
    required this.from,
    required this.to,
    this.oneway = false,
    this.weight = 1.0,
  });

  factory NavEdge.fromJson(Map<String, dynamic> json) => NavEdge(
        from: json['from'] as String,
        to: json['to'] as String,
        oneway: json['oneway'] as bool? ?? false,
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
      );
}

// ──────────────────────────────────────────────
// 3. Priority Queue (Min-Heap) for A*
// ──────────────────────────────────────────────

class _PriorityEntry implements Comparable<_PriorityEntry> {
  final String nodeId;
  final double fScore;
  _PriorityEntry(this.nodeId, this.fScore);

  @override
  int compareTo(_PriorityEntry other) => fScore.compareTo(other.fScore);
}

class _MinHeap {
  final List<_PriorityEntry> _heap = [];
  bool get isNotEmpty => _heap.isNotEmpty;

  void add(String nodeId, double fScore) {
    _heap.add(_PriorityEntry(nodeId, fScore));
    _bubbleUp(_heap.length - 1);
  }

  _PriorityEntry removeMin() {
    final min = _heap.first;
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _bubbleDown(0);
    }
    return min;
  }

  void _bubbleUp(int i) {
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_heap[i].compareTo(_heap[parent]) >= 0) break;
      _swap(i, parent);
      i = parent;
    }
  }

  void _bubbleDown(int i) {
    final n = _heap.length;
    while (true) {
      int smallest = i;
      final left = 2 * i + 1;
      final right = 2 * i + 2;
      if (left < n && _heap[left].compareTo(_heap[smallest]) < 0) smallest = left;
      if (right < n && _heap[right].compareTo(_heap[smallest]) < 0) smallest = right;
      if (smallest == i) break;
      _swap(i, smallest);
      i = smallest;
    }
  }

  void _swap(int a, int b) {
    final temp = _heap[a];
    _heap[a] = _heap[b];
    _heap[b] = temp;
  }
}

// ──────────────────────────────────────────────
// 4. NavGraph — Mall Map + A* Pathfinding
// ──────────────────────────────────────────────

class NavGraph {
  final Map<String, NavNode> nodes = {};
  final Map<String, List<({String neighborId, double cost})>> adjacency = {};

  NavGraph.fromJson(Map<String, dynamic> json) {
    for (final n in json['nodes'] as List) {
      final node = NavNode.fromJson(n as Map<String, dynamic>);
      nodes[node.id] = node;
      adjacency[node.id] = [];
    }
    for (final e in json['edges'] as List) {
      final edge = NavEdge.fromJson(e as Map<String, dynamic>);
      final distance = nodes[edge.from]!.position.distanceTo(nodes[edge.to]!.position);
      final cost = distance * edge.weight;
      adjacency[edge.from]!.add((neighborId: edge.to, cost: cost));
      if (!edge.oneway) {
        adjacency[edge.to]!.add((neighborId: edge.from, cost: cost));
      }
    }
  }

  List<NavNode>? findPath(String startId, String goalId) {
    if (!nodes.containsKey(startId) || !nodes.containsKey(goalId)) return null;
    if (startId == goalId) return [nodes[startId]!];

    final goalPos = nodes[goalId]!.position;
    final gScore = <String, double>{startId: 0.0};
    final fScore = <String, double>{startId: nodes[startId]!.position.distanceTo(goalPos)};
    final cameFrom = <String, String>{};
    final closedSet = <String>{};
    final openSet = _MinHeap()..add(startId, fScore[startId]!);

    while (openSet.isNotEmpty) {
      final current = openSet.removeMin().nodeId;
      if (current == goalId) return _reconstructPath(cameFrom, current);
      if (closedSet.contains(current)) continue;
      closedSet.add(current);

      for (final neighbor in adjacency[current]!) {
        if (closedSet.contains(neighbor.neighborId)) continue;
        final tentativeG = gScore[current]! + neighbor.cost;
        if (tentativeG < (gScore[neighbor.neighborId] ?? double.infinity)) {
          cameFrom[neighbor.neighborId] = current;
          gScore[neighbor.neighborId] = tentativeG;
          final f = tentativeG + nodes[neighbor.neighborId]!.position.distanceTo(goalPos);
          openSet.add(neighbor.neighborId, f);
        }
      }
    }
    return null;
  }

  List<NavNode> _reconstructPath(Map<String, String> cameFrom, String current) {
    final path = <NavNode>[nodes[current]!];
    var node = current;
    while (cameFrom.containsKey(node)) {
      node = cameFrom[node]!;
      path.add(nodes[node]!);
    }
    return path.reversed.toList();
  }

  double pathDistance(List<NavNode> path) {
    double total = 0;
    for (int i = 0; i < path.length - 1; i++) {
      total += path[i].position.distanceTo(path[i + 1].position);
    }
    return total;
  }

  /// Finds the closest node to a given position.
  /// Used to determine which node the user is nearest to.
  String findNearestNode(Vector3 position) {
    String nearestId = nodes.keys.first;
    double nearestDist = double.infinity;

    for (final node in nodes.values) {
      final dist = position.distanceTo(node.position);
      if (dist < nearestDist) {
        nearestDist = dist;
        nearestId = node.id;
      }
    }
    return nearestId;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 5. CoordinateAligner
//
// THE MOST CRITICAL CLASS — bridges the gap between two coordinate systems:
//
//   Mall Map Coordinates:  Fixed positions you measured (e.g., door = (0,0,0))
//   AR Session Coordinates: ARCore's world, where (0,0,0) = where the session started
//
// When the user scans a QR code at a KNOWN map position, we can calculate
// the offset between these two systems. After that, we can convert freely.
//
// Example:
//   QR code is at map position (0, 0, 0)        ← you know this
//   ARCore says camera sees QR at (0.3, -0.1, -0.5) ← ARCore tells you this
//   Offset = AR position - Map position = (0.3, -0.1, -0.5)
//
//   Now, when ARCore says you're at (2.3, -0.1, -0.5):
//   Map position = AR position - offset = (2.0, 0.0, 0.0)  ← you're at the 2m mark!
// ══════════════════════════════════════════════════════════════════════════════

class CoordinateAligner {
  /// The offset from map coordinates to AR coordinates.
  /// null means we haven't aligned yet (no QR scanned).
  Vector3? _offset;

  /// The rotation offset between map north and AR north (in radians).
  /// For simplicity, we start with 0 and can refine with multiple QR scans.
  double _yawOffset = 0.0;

  /// Whether the coordinate systems have been aligned.
  bool get isAligned => _offset != null;

  /// Call this when the user scans a QR code.
  ///
  /// [knownMapPosition] — the QR code's position in the mall map (from your JSON).
  /// [arDetectedPosition] — where ARCore says the camera is when it sees the QR.
  /// [arCameraYaw] — the camera's Y-axis rotation in AR space (optional, for rotation alignment).
  /// [knownMapYaw] — the direction the QR code faces in map space (optional).
  void alignFromQRCode({
    required Vector3 knownMapPosition,
    required Vector3 arDetectedPosition,
    double? arCameraYaw,
    double? knownMapYaw,
  }) {
    forceAlignment(
      knownMapPosition: knownMapPosition,
      arPosition: arDetectedPosition,
      mapYaw: knownMapYaw,
      arYaw: arCameraYaw,
    );
  }

  /// Manually set the alignment between coordinate systems.
  ///
  /// [knownMapPosition] — where you are on the map.
  /// [arPosition] — where ARCore says you are in its world.
  void forceAlignment({
    required Vector3 knownMapPosition,
    required Vector3 arPosition,
    double? mapYaw,
    double? arYaw,
  }) {
    _offset = arPosition - knownMapPosition;
    if (mapYaw != null && arYaw != null) {
      _yawOffset = arYaw - mapYaw;
    }
    print('[Aligner] Forced Alignment! Offset: $_offset, Yaw offset: $_yawOffset rad');
  }

  /// Converts an AR position (from ARCore) to a map position (your mall JSON).
  /// Call this every frame to know where the user is on the map.
  ///
  /// Returns null if not yet aligned (QR code hasn't been scanned).
  Vector3? arToMap(Vector3 arPosition) {
    if (_offset == null) return null;

    // Simple translation (no rotation):
    // mapPosition = arPosition - offset
    return arPosition - _offset!;

    // TODO: For production, apply yaw rotation here:
    // 1. Subtract offset to translate to map origin
    // 2. Rotate around Y axis by -_yawOffset
    // This handles when the user scans the QR at an angle
  }

  /// Converts a map position (from your mall JSON) to an AR position.
  /// Used to place the 3D avatar at the correct spot in the AR world.
  ///
  /// Returns null if not yet aligned.
  Vector3? mapToAR(Vector3 mapPosition) {
    if (_offset == null) return null;

    // mapPosition + offset = arPosition
    return mapPosition + _offset!;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 6. QR Anchor Registry
//
// Maps QR code values to known positions in the mall map.
// In a real mall, you'd print QR codes with unique IDs and place them
// at measured positions throughout the building.
//
// For home testing: print 1-2 QR codes, tape them to known spots,
// and hardcode their positions here.
// ══════════════════════════════════════════════════════════════════════════════

class QRAnchorRegistry {
  /// Maps QR code string content → known position in mall coordinates.
  final Map<String, Vector3> _anchors = {};

  /// Register a QR code anchor at a known map position.
  void register(String qrValue, Vector3 mapPosition) {
    _anchors[qrValue] = mapPosition;
  }

  /// Look up the map position for a scanned QR code.
  /// Returns null if the QR code isn't registered (unknown QR).
  Vector3? lookup(String qrValue) => _anchors[qrValue];

  /// Load anchors from a JSON list.
  /// Example JSON:
  /// [
  ///   {"qr": "MALL_DOOR_01", "x": 0, "y": 0, "z": 0},
  ///   {"qr": "MALL_LOBBY_01", "x": 8, "y": 0, "z": 5}
  /// ]
  void loadFromJson(List<Map<String, dynamic>> json) {
    for (final anchor in json) {
      _anchors[anchor['qr'] as String] = Vector3.fromJson(anchor);
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 7. AvatarGuide
//
// Controls the 3D avatar that walks ahead of the user.
// It follows the computed path waypoint by waypoint:
//   1. Avatar stands at the NEXT waypoint the user needs to reach.
//   2. When the user gets close enough (within arrivalThreshold), 
//      the avatar moves to the FOLLOWING waypoint.
//   3. When the user reaches the final waypoint, navigation is complete.
// ══════════════════════════════════════════════════════════════════════════════

/// The current state of the avatar navigation.
enum NavigationState {
  /// Waiting for QR scan to align coordinates.
  waitingForAlignment,

  /// User has selected a destination, avatar is guiding them.
  navigating,

  /// User has arrived at the destination.
  arrived,

  /// No path could be found to the destination.
  noPathFound,
}

class AvatarGuide {
  /// The full path from start to destination (list of waypoint nodes).
  List<NavNode> _path = [];

  /// Index of the NEXT waypoint the user needs to reach.
  /// The avatar stands at _path[_currentWaypointIndex].
  int _currentWaypointIndex = 0;

  /// How close (in meters) the user needs to be to a waypoint
  /// before we consider them "arrived" and move the avatar forward.
  /// 0.8m works well for indoor AR — not too tight, not too loose.
  final double arrivalThreshold;

  /// Current navigation state.
  NavigationState state = NavigationState.waitingForAlignment;

  /// Callback: fired when the avatar moves to the next waypoint.
  /// Use this to update the 3D model's position in the AR scene.
  void Function(NavNode nextWaypoint)? onAvatarMoved;

  /// Callback: fired when the user arrives at the destination.
  void Function()? onArrived;

  /// Callback: fired every frame with updated distance info.
  void Function(double distanceToNext, double totalRemaining)? onDistanceUpdate;

  AvatarGuide({this.arrivalThreshold = 0.8});

  /// Start navigating along a computed path.
  /// [path] is the result of NavGraph.findPath().
  void startNavigation(List<NavNode> path) {
    _path = path;

    // Start at index 1, not 0, because index 0 is where the user already is.
    // The avatar should appear at the NEXT place to walk toward.
    _currentWaypointIndex = 1;

    state = NavigationState.navigating;

    // Tell the AR scene to place the avatar at the first waypoint to walk to.
    if (onAvatarMoved != null && _path.length > 1) {
      onAvatarMoved!(_path[_currentWaypointIndex]);
    }

    print('[Avatar] Navigation started. ${_path.length} waypoints, '
        'heading to: ${_path[_currentWaypointIndex].id}');
  }

  /// Call this EVERY FRAME with the user's current position in MAP coordinates.
  /// This is the heart of the real-time tracking.
  ///
  /// [userMapPosition] — the user's current position, converted from AR to map coords.
  void update(Vector3 userMapPosition) {
    // Don't do anything if we're not actively navigating.
    if (state != NavigationState.navigating) return;

    // Safety check: make sure we haven't gone past the end of the path.
    if (_currentWaypointIndex >= _path.length) {
      state = NavigationState.arrived;
      onArrived?.call();
      return;
    }

    // Get the position of the waypoint the user is walking toward.
    final targetWaypoint = _path[_currentWaypointIndex];
    final distanceToTarget = userMapPosition.distanceTo(targetWaypoint.position);

    // Calculate total remaining distance (sum of all remaining segments).
    final totalRemaining = _calculateRemainingDistance(userMapPosition);

    // Fire the distance update callback (for UI: "50m remaining").
    onDistanceUpdate?.call(distanceToTarget, totalRemaining);

    // ── Check: Has the user reached the current waypoint? ──
    // If the user is within arrivalThreshold meters of the target,
    // they've "arrived" at this waypoint.
    if (distanceToTarget < arrivalThreshold) {
      print('[Avatar] Reached waypoint: ${targetWaypoint.id} '
          '(dist: ${distanceToTarget.toStringAsFixed(2)}m)');

      // Move to the next waypoint in the path.
      _currentWaypointIndex++;

      // ── Check: Was that the LAST waypoint (the destination)? ──
      if (_currentWaypointIndex >= _path.length) {
        // The user has arrived at their destination!
        state = NavigationState.arrived;
        onArrived?.call();
        print('[Avatar] ARRIVED at destination!');
        return;
      }

      // There are more waypoints — move the avatar to the next one.
      final nextWaypoint = _path[_currentWaypointIndex];
      onAvatarMoved?.call(nextWaypoint);
      print('[Avatar] Moving to next waypoint: ${nextWaypoint.id}');
    }
  }

  /// Calculates the total remaining walking distance from the user's
  /// current position to the final destination.
  double _calculateRemainingDistance(Vector3 userPosition) {
    if (_currentWaypointIndex >= _path.length) return 0;

    // Distance from user to the next waypoint.
    double remaining = userPosition.distanceTo(
      _path[_currentWaypointIndex].position,
    );

    // Plus the distance of all remaining path segments.
    for (int i = _currentWaypointIndex; i < _path.length - 1; i++) {
      remaining += _path[i].position.distanceTo(_path[i + 1].position);
    }

    return remaining;
  }

  /// Get the current waypoint the avatar is standing at.
  NavNode? get currentTarget =>
      (_currentWaypointIndex < _path.length) ? _path[_currentWaypointIndex] : null;

  /// Get the position where the avatar should be placed (in map coordinates).
  Vector3? get avatarMapPosition => currentTarget?.position;
}

// ══════════════════════════════════════════════════════════════════════════════
// 8. NavigationSession — Ties Everything Together
//
// This is the main controller class your Flutter widget will interact with.
// It manages the full flow:
//   1. Load the mall map.
//   2. Wait for QR scan → align coordinates.
//   3. User picks a destination → compute path.
//   4. Every AR frame → update user position → move avatar.
// ══════════════════════════════════════════════════════════════════════════════

class NavigationSession {
  final NavGraph graph;
  final CoordinateAligner aligner = CoordinateAligner();
  final QRAnchorRegistry qrRegistry = QRAnchorRegistry();
  final AvatarGuide avatar;

  /// Debug info updated every frame — display this in a debug overlay.
  String debugInfo = '';

  NavigationSession({
    required this.graph,
    double arrivalThreshold = 0.8,
  }) : avatar = AvatarGuide(arrivalThreshold: arrivalThreshold);

  // ──────────────────────────────────────────
  // Step 1: Register QR Anchors
  // Call this once at startup with your QR code positions.
  // ──────────────────────────────────────────

  void registerQRAnchor(String qrValue, Vector3 mapPosition) {
    qrRegistry.register(qrValue, mapPosition);
  }

  // ──────────────────────────────────────────
  // Step 2: Handle QR Code Scan
  // Call this when the mobile_scanner detects a QR code.
  // ──────────────────────────────────────────

  /// Processes a scanned QR code and aligns coordinate systems.
  ///
  /// [qrValue] — the text content of the QR code.
  /// [arCameraPosition] — the AR camera's position when the QR was scanned.
  ///
  /// Returns true if alignment succeeded, false if QR is unknown.
  bool onQRCodeScanned(String qrValue, Vector3 arCameraPosition) {
    // Look up the QR code in our registry.
    final mapPosition = qrRegistry.lookup(qrValue);

    // If we don't recognize this QR code, ignore it.
    if (mapPosition == null) {
      print('[Session] Unknown QR code: $qrValue');
      return false;
    }

    // Align the coordinate systems using the known map position
    // and the AR camera position where we detected the QR.
    aligner.forceAlignment(
      knownMapPosition: mapPosition,
      arPosition: arCameraPosition,
    );

    print('[Session] Aligned via QR "$qrValue" at map position $mapPosition');
    return true;
  }

  /// Initializes the session at a default map position (typically origin 0,0,0).
  /// Call this if you want to skip QR scanning.
  void initializeDefaultAlignment(Vector3 arCameraPosition) {
    // We assume the user is standing at (0, 0, 0) on the map.
    final defaultMapPos = Vector3(0, 0, 0);

    aligner.forceAlignment(
      knownMapPosition: defaultMapPos,
      arPosition: arCameraPosition,
    );

    print('[Session] Initialized with default alignment at $defaultMapPos');
  }

  // ──────────────────────────────────────────
  // Step 3: Start Navigation to a Destination
  // Call this when the user picks a shop.
  // ──────────────────────────────────────────

  /// Starts navigation from the user's current position to a destination.
  ///
  /// [destinationNodeId] — the target node ID (e.g., "shop_nike").
  /// [currentARPosition] — the user's current AR camera position.
  ///
  /// Returns true if a path was found and navigation started.
  bool navigateTo(String destinationNodeId, Vector3 currentARPosition) {
    // First, convert the user's AR position to map coordinates.
    final mapPos = aligner.arToMap(currentARPosition);
    if (mapPos == null) {
      print('[Session] Cannot navigate: coordinates not aligned. Scan a QR code first.');
      return false;
    }

    // Find the nearest node to the user's current map position.
    // This becomes the starting point for pathfinding.
    final nearestNodeId = graph.findNearestNode(mapPos);

    // Run A* pathfinding from nearest node to destination.
    final path = graph.findPath(nearestNodeId, destinationNodeId);

    if (path == null) {
      print('[Session] No path found from $nearestNodeId to $destinationNodeId');
      avatar.state = NavigationState.noPathFound;
      return false;
    }

    // Start the avatar navigation along the computed path.
    avatar.startNavigation(path);

    final distance = graph.pathDistance(path);
    print('[Session] Path found! ${path.length} waypoints, '
        '${distance.toStringAsFixed(1)}m total');

    return true;
  }

  // ──────────────────────────────────────────
  // Step 4: Frame Update (call every AR frame)
  // This is the real-time tracking loop.
  // ──────────────────────────────────────────

  /// Call this every AR frame with the camera's current position.
  /// This updates the user's position, checks waypoint proximity,
  /// and moves the avatar as needed.
  ///
  /// Returns the avatar's position in AR coordinates (for placing the 3D model),
  /// or null if not navigating.
  Vector3? onARFrameUpdate(Vector3 arCameraPosition) {
    // Convert AR position to map position.
    final mapPos = aligner.arToMap(arCameraPosition);
    if (mapPos == null) return null;

    // Update the avatar with the user's current map position.
    // This checks waypoint proximity and advances the avatar.
    avatar.update(mapPos);

    // Build debug info string for the overlay.
    debugInfo = 'AR: $arCameraPosition\n'
        'Map: $mapPos\n'
        'State: ${avatar.state}\n'
        'Target: ${avatar.currentTarget?.id ?? "none"}';

    // Convert the avatar's map position to AR coordinates
    // so we know where to render the 3D model in the AR scene.
    if (avatar.avatarMapPosition != null) {
      return aligner.mapToAR(avatar.avatarMapPosition!);
    }

    return null;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 9. Example: Full Usage (how you'd use this in your Flutter app)
// ══════════════════════════════════════════════════════════════════════════════

void main() {
  // ── Load the mall map ──
  final mallJson = {
    "nodes": [
      {"id": "door", "x": 0, "y": 0, "z": 0, "shopName": null},
      {"id": "middle", "x": 2, "y": 0, "z": 0, "shopName": null},
      {"id": "desk", "x": 4, "y": 0, "z": 0, "shopName": "Desk"},
      {"id": "bed", "x": 2, "y": 0, "z": 3, "shopName": "Bed"},
    ],
    "edges": [
      {"from": "door", "to": "middle"},
      {"from": "middle", "to": "desk"},
      {"from": "middle", "to": "bed"},
    ],
  };

  final graph = NavGraph.fromJson(mallJson);

  // ── Create the navigation session ──
  final session = NavigationSession(graph: graph);

  // ── Register QR codes ──
  // You printed a QR code that says "ROOM_DOOR" and taped it to the door.
  session.registerQRAnchor('ROOM_DOOR', Vector3(0, 0, 0));

  // ── Set up avatar callbacks ──
  session.avatar.onAvatarMoved = (waypoint) {
    print('>> AVATAR moved to: ${waypoint.id} at ${waypoint.position}');
    // In real app: update the 3D model position in AR scene
  };

  session.avatar.onArrived = () {
    print('>> YOU HAVE ARRIVED! 🎉');
    // In real app: play celebration animation, show "You've arrived" UI
  };

  session.avatar.onDistanceUpdate = (distToNext, totalRemaining) {
    print('>> ${totalRemaining.toStringAsFixed(1)}m remaining');
    // In real app: update the distance label in the UI
  };

  // ══════════════════════════════════════════
  // Simulate what happens in real life:
  // ══════════════════════════════════════════

  print('=== Step 1: User scans QR code at the door ===');
  // User opens app, points camera at QR on the door.
  // ARCore says the camera is at (0.3, -0.1, -0.5) in AR space.
  session.onQRCodeScanned('ROOM_DOOR', Vector3(0.3, -0.1, -0.5));

  print('\n=== Step 2: User selects "Desk" as destination ===');
  // User taps "Desk" in the app. Current AR position is still near the door.
  session.navigateTo('desk', Vector3(0.3, -0.1, -0.5));

  print('\n=== Step 3: User starts walking ===');

  // Frame 1: User is still at the door
  print('\n--- Frame 1: At door ---');
  var avatarAR = session.onARFrameUpdate(Vector3(0.3, -0.1, -0.5));
  print('Avatar AR position: $avatarAR');

  // Frame 2: User walked 1 meter (halfway to "middle")
  print('\n--- Frame 2: Walking... ---');
  avatarAR = session.onARFrameUpdate(Vector3(1.3, -0.1, -0.5));
  print('Avatar AR position: $avatarAR');

  // Frame 3: User reached "middle" (2m from door)
  print('\n--- Frame 3: Near "middle" waypoint ---');
  avatarAR = session.onARFrameUpdate(Vector3(2.1, -0.1, -0.5));
  print('Avatar AR position: $avatarAR');

  // Frame 4: User is between middle and desk (3m from door)
  print('\n--- Frame 4: Walking to desk... ---');
  avatarAR = session.onARFrameUpdate(Vector3(3.3, -0.1, -0.5));
  print('Avatar AR position: $avatarAR');

  // Frame 5: User reached "desk" (4m from door)
  print('\n--- Frame 5: At desk ---');
  avatarAR = session.onARFrameUpdate(Vector3(4.2, -0.1, -0.5));
  print('Avatar AR position: $avatarAR');
}
