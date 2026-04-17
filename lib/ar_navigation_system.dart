import 'dart:math' as math;
import 'dart:developer';

// ═══════════════════════════════════════════════════════════════
// Vector3
// ═══════════════════════════════════════════════════════════════

class Vector3 {
  final double x, y, z;
  const Vector3(this.x, this.y, this.z);

  double distanceTo(Vector3 o) {
    final dx = x - o.x, dy = y - o.y, dz = z - o.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  Vector3 operator -(Vector3 o) => Vector3(x - o.x, y - o.y, z - o.z);
  Vector3 operator +(Vector3 o) => Vector3(x + o.x, y + o.y, z + o.z);

  factory Vector3.fromJson(Map<String, dynamic> j) => Vector3(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        (j['z'] as num).toDouble(),
      );

  @override
  String toString() =>
      '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})';
}

// ═══════════════════════════════════════════════════════════════
// NavNode / NavEdge
// ═══════════════════════════════════════════════════════════════

class NavNode {
  final String id;
  final Vector3 position;
  final String? shopName;
  const NavNode({required this.id, required this.position, this.shopName});
  factory NavNode.fromJson(Map<String, dynamic> j) => NavNode(
        id: j['id'] as String,
        position: Vector3.fromJson(j),
        shopName: j['shopName'] as String?,
      );
}

class NavEdge {
  final String from, to;
  final bool oneway;
  final double weight;
  const NavEdge({required this.from, required this.to, this.oneway = false, this.weight = 1.0});
  factory NavEdge.fromJson(Map<String, dynamic> j) => NavEdge(
        from: j['from'] as String,
        to: j['to'] as String,
        oneway: j['oneway'] as bool? ?? false,
        weight: (j['weight'] as num?)?.toDouble() ?? 1.0,
      );
}

// ═══════════════════════════════════════════════════════════════
// Min-Heap
// ═══════════════════════════════════════════════════════════════

class _PE implements Comparable<_PE> {
  final String nodeId;
  final double f;
  _PE(this.nodeId, this.f);
  @override
  int compareTo(_PE o) => f.compareTo(o.f);
}

class _MinHeap {
  final List<_PE> _h = [];
  bool get isNotEmpty => _h.isNotEmpty;
  void add(String id, double f) { _h.add(_PE(id, f)); _up(_h.length - 1); }
  _PE removeMin() {
    final m = _h.first; final l = _h.removeLast();
    if (_h.isNotEmpty) { _h[0] = l; _down(0); }
    return m;
  }
  void _up(int i) { while (i > 0) { final p = (i-1)~/2; if (_h[i].compareTo(_h[p])>=0) break; _sw(i,p); i=p; } }
  void _down(int i) { final n=_h.length; while(true) { int s=i; final l=2*i+1,r=2*i+2; if(l<n&&_h[l].compareTo(_h[s])<0)s=l; if(r<n&&_h[r].compareTo(_h[s])<0)s=r; if(s==i)break; _sw(i,s); i=s; } }
  void _sw(int a, int b) { final t=_h[a]; _h[a]=_h[b]; _h[b]=t; }
}

// ═══════════════════════════════════════════════════════════════
// NavGraph + A*
// ═══════════════════════════════════════════════════════════════

class NavGraph {
  final Map<String, NavNode> nodes = {};
  final Map<String, List<({String neighborId, double cost})>> adjacency = {};

  NavGraph.fromJson(Map<String, dynamic> json) {
    log('Building graph from JSON...', name: 'NAV');
    for (final n in json['nodes'] as List) {
      final node = NavNode.fromJson(n as Map<String, dynamic>);
      nodes[node.id] = node;
      adjacency[node.id] = [];
    }
    log('Loaded ${nodes.length} nodes', name: 'NAV');

    int edgeCount = 0;
    for (final e in json['edges'] as List) {
      final edge = NavEdge.fromJson(e as Map<String, dynamic>);
      final dist = nodes[edge.from]!.position.distanceTo(nodes[edge.to]!.position);
      final cost = dist * edge.weight;
      adjacency[edge.from]!.add((neighborId: edge.to, cost: cost));
      if (!edge.oneway) adjacency[edge.to]!.add((neighborId: edge.from, cost: cost));
      edgeCount++;
    }
    log('Loaded $edgeCount edges. Graph ready.', name: 'NAV');
  }

  List<NavNode>? findPath(String startId, String goalId) {
    log('findPath("$startId" → "$goalId")', name: 'NAV');
    if (!nodes.containsKey(startId) || !nodes.containsKey(goalId)) {
      log('ERROR: Node not found! start=$startId exists=${nodes.containsKey(startId)}, goal=$goalId exists=${nodes.containsKey(goalId)}', name: 'NAV');
      return null;
    }
    if (startId == goalId) { log('Start == Goal, returning single node', name: 'NAV'); return [nodes[startId]!]; }

    final goalPos = nodes[goalId]!.position;
    final gScore = <String, double>{startId: 0.0};
    final cameFrom = <String, String>{};
    final closed = <String>{};
    final open = _MinHeap()..add(startId, nodes[startId]!.position.distanceTo(goalPos));
    int explored = 0;

    while (open.isNotEmpty) {
      final cur = open.removeMin().nodeId;
      if (cur == goalId) {
        final path = _reconstruct(cameFrom, cur);
        final dist = pathDistance(path);
        log('✓ Path found: ${path.length} nodes, ${dist.toStringAsFixed(1)}m, explored $explored', name: 'NAV');
        for (int i = 0; i < path.length; i++) {
          log('  [$i] ${path[i].id} ${path[i].position}${path[i].shopName != null ? " (${path[i].shopName})" : ""}', name: 'NAV');
        }
        return path;
      }
      if (closed.contains(cur)) continue;
      closed.add(cur);
      explored++;
      for (final nb in adjacency[cur]!) {
        if (closed.contains(nb.neighborId)) continue;
        final tg = gScore[cur]! + nb.cost;
        if (tg < (gScore[nb.neighborId] ?? double.infinity)) {
          cameFrom[nb.neighborId] = cur;
          gScore[nb.neighborId] = tg;
          open.add(nb.neighborId, tg + nodes[nb.neighborId]!.position.distanceTo(goalPos));
        }
      }
    }
    log('✗ No path found from $startId to $goalId after exploring $explored nodes', name: 'NAV');
    return null;
  }

  List<NavNode> _reconstruct(Map<String, String> cf, String c) {
    final p = <NavNode>[nodes[c]!];
    var n = c;
    while (cf.containsKey(n)) { n = cf[n]!; p.add(nodes[n]!); }
    return p.reversed.toList();
  }

  double pathDistance(List<NavNode> path) {
    double t = 0;
    for (int i = 0; i < path.length - 1; i++) t += path[i].position.distanceTo(path[i + 1].position);
    return t;
  }

  String findNearestNode(Vector3 pos) {
    String nearest = nodes.keys.first;
    double nearestDist = double.infinity;
    for (final node in nodes.values) {
      final d = pos.distanceTo(node.position);
      if (d < nearestDist) { nearestDist = d; nearest = node.id; }
    }
    log('Nearest node to $pos → "$nearest" (${nearestDist.toStringAsFixed(2)}m)', name: 'NAV');
    return nearest;
  }
}

// ═══════════════════════════════════════════════════════════════
// CoordinateAligner
// ═══════════════════════════════════════════════════════════════

class CoordinateAligner {
  Vector3? _offset;
  double _yawOffset = 0.0;
  bool get isAligned => _offset != null;

  void alignFromQRCode({required Vector3 knownMapPosition, required Vector3 arDetectedPosition, double? arCameraYaw, double? knownMapYaw}) {
    _offset = arDetectedPosition - knownMapPosition;
    if (arCameraYaw != null && knownMapYaw != null) _yawOffset = arCameraYaw - knownMapYaw;
    log('Aligned! offset=$_offset yawOffset=${_yawOffset.toStringAsFixed(3)} rad', name: 'ALIGN');
    log('  mapPos=$knownMapPosition arPos=$arDetectedPosition', name: 'ALIGN');
  }

  Vector3? arToMap(Vector3 arPos) {
    if (_offset == null) { log('arToMap called but NOT aligned!', name: 'ALIGN'); return null; }
    return arPos - _offset!;
  }

  Vector3? mapToAR(Vector3 mapPos) {
    if (_offset == null) { log('mapToAR called but NOT aligned!', name: 'ALIGN'); return null; }
    return mapPos + _offset!;
  }
}

// ═══════════════════════════════════════════════════════════════
// QRAnchorRegistry
// ═══════════════════════════════════════════════════════════════

class QRAnchorRegistry {
  final Map<String, Vector3> _anchors = {};
  void register(String qr, Vector3 pos) { _anchors[qr] = pos; log('Registered QR "$qr" at $pos', name: 'QR'); }
  Vector3? lookup(String qr) { final p = _anchors[qr]; log('Lookup QR "$qr" → ${p ?? "NOT FOUND"}', name: 'QR'); return p; }
  void loadFromJson(List<Map<String, dynamic>> json) { for (final a in json) { _anchors[a['qr'] as String] = Vector3.fromJson(a); } log('Loaded ${json.length} QR anchors', name: 'QR'); }
}

// ═══════════════════════════════════════════════════════════════
// AvatarGuide
// ═══════════════════════════════════════════════════════════════

enum NavigationState { waitingForAlignment, navigating, arrived, noPathFound }

class AvatarGuide {
  List<NavNode> _path = [];
  int _currentWaypointIndex = 0;
  final double arrivalThreshold;
  NavigationState state = NavigationState.waitingForAlignment;

  void Function(NavNode nextWaypoint)? onAvatarMoved;
  void Function()? onArrived;
  void Function(double distanceToNext, double totalRemaining)? onDistanceUpdate;

  AvatarGuide({this.arrivalThreshold = 0.8});

  void startNavigation(List<NavNode> path) {
    _path = path;
    _currentWaypointIndex = 1;
    state = NavigationState.navigating;
    log('Navigation started. ${_path.length} waypoints. First target: ${_path[_currentWaypointIndex].id}', name: 'AVATAR');
    if (onAvatarMoved != null && _path.length > 1) onAvatarMoved!(_path[_currentWaypointIndex]);
  }

  void update(Vector3 userPos) {
    if (state != NavigationState.navigating) return;
    if (_currentWaypointIndex >= _path.length) { state = NavigationState.arrived; onArrived?.call(); return; }

    final target = _path[_currentWaypointIndex];
    final dist = userPos.distanceTo(target.position);
    final totalRemaining = _calcRemaining(userPos);
    onDistanceUpdate?.call(dist, totalRemaining);

    if (dist < arrivalThreshold) {
      log('Reached waypoint: ${target.id} (dist=${dist.toStringAsFixed(2)}m)', name: 'AVATAR');
      _currentWaypointIndex++;
      if (_currentWaypointIndex >= _path.length) {
        state = NavigationState.arrived;
        log('★ ARRIVED at destination!', name: 'AVATAR');
        onArrived?.call();
        return;
      }
      final next = _path[_currentWaypointIndex];
      log('Moving avatar to: ${next.id} at ${next.position}', name: 'AVATAR');
      onAvatarMoved?.call(next);
    }
  }

  double _calcRemaining(Vector3 userPos) {
    if (_currentWaypointIndex >= _path.length) return 0;
    double r = userPos.distanceTo(_path[_currentWaypointIndex].position);
    for (int i = _currentWaypointIndex; i < _path.length - 1; i++) r += _path[i].position.distanceTo(_path[i + 1].position);
    return r;
  }

  NavNode? get currentTarget => (_currentWaypointIndex < _path.length) ? _path[_currentWaypointIndex] : null;
  Vector3? get avatarMapPosition => currentTarget?.position;
}

// ═══════════════════════════════════════════════════════════════
// NavigationSession
// ═══════════════════════════════════════════════════════════════

class NavigationSession {
  final NavGraph graph;
  final CoordinateAligner aligner = CoordinateAligner();
  final QRAnchorRegistry qrRegistry = QRAnchorRegistry();
  final AvatarGuide avatar;
  String debugInfo = '';

  NavigationSession({required this.graph, double arrivalThreshold = 0.8})
      : avatar = AvatarGuide(arrivalThreshold: arrivalThreshold) {
    log('Session created. ${graph.nodes.length} nodes.', name: 'SESSION');
  }

  void registerQRAnchor(String qr, Vector3 pos) => qrRegistry.register(qr, pos);

  bool onQRCodeScanned(String qrValue, Vector3 arCameraPosition) {
    log('QR scanned: "$qrValue" at AR pos $arCameraPosition', name: 'SESSION');
    final mapPos = qrRegistry.lookup(qrValue);
    if (mapPos == null) { log('Unknown QR code: "$qrValue"', name: 'SESSION'); return false; }
    aligner.alignFromQRCode(knownMapPosition: mapPos, arDetectedPosition: arCameraPosition);
    log('✓ Aligned via QR "$qrValue"', name: 'SESSION');
    return true;
  }

  bool navigateTo(String destId, Vector3 currentARPos) {
    log('navigateTo("$destId") from AR pos $currentARPos', name: 'SESSION');
    final mapPos = aligner.arToMap(currentARPos);
    if (mapPos == null) { log('Cannot navigate: not aligned!', name: 'SESSION'); return false; }
    log('User map position: $mapPos', name: 'SESSION');

    final nearestId = graph.findNearestNode(mapPos);
    final path = graph.findPath(nearestId, destId);
    if (path == null) { log('No path found!', name: 'SESSION'); avatar.state = NavigationState.noPathFound; return false; }

    avatar.startNavigation(path);
    log('✓ Navigation started to "$destId"', name: 'SESSION');
    return true;
  }

  Vector3? onARFrameUpdate(Vector3 arCameraPos) {
    final mapPos = aligner.arToMap(arCameraPos);
    if (mapPos == null) return null;
    avatar.update(mapPos);
    debugInfo = 'AR:$arCameraPos\nMap:$mapPos\nState:${avatar.state}\nTarget:${avatar.currentTarget?.id ?? "none"}';
    if (avatar.avatarMapPosition != null) return aligner.mapToAR(avatar.avatarMapPosition!);
    return null;
  }
}
