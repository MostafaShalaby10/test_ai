import 'dart:async';
import 'dart:math' as math;


import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/widgets/ar_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AR Navigation Demo',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const QRScannerPage(destinationNodeId: 'desk'),
    );
  }
}

/// ---------------------------
/// 1) QR SCREEN
/// ---------------------------

class QRScannerPage extends StatefulWidget {
  final String destinationNodeId;

  const QRScannerPage({
    super.key,
    required this.destinationNodeId,
  });

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage>
    with WidgetsBindingObserver {
  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: false,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );

  bool _handled = false;
  bool _scannerStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _startScannerSafely();
    });
  }

  Future<void> _startScannerSafely() async {
    if (_scannerStarted) return;
    try {
      await _scannerController.start();
      _scannerStarted = true;
    } catch (_) {
      // Ignore controller state races.
    }
  }

  Future<void> _stopScannerSafely() async {
    if (!_scannerStarted) return;
    try {
      await _scannerController.stop();
    } catch (_) {
      // Ignore stop races.
    } finally {
      _scannerStarted = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || _handled) return;

    if (state == AppLifecycleState.resumed) {
      _startScannerSafely();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopScannerSafely();
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;

    final String? qrValue = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue
        : null;

    if (qrValue == null || qrValue.trim().isEmpty) return;

    _handled = true;
    await _stopScannerSafely();

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ARNavigationPage(
          scannedQrValue: qrValue,
          destinationNodeId: widget.destinationNodeId,
          graph: DemoData.buildGraph(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR first'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scannerController,
            useAppLifecycleState: false,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Scanner error:\n${error.errorCode}\n${error.errorDetails?.message ?? ''}',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Point the camera at a registered QR code.\nThe scanner will close automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------
/// 2) AR SCREEN
/// ---------------------------

class ARNavigationPage extends StatefulWidget {
  final String scannedQrValue;
  final String destinationNodeId;
  final NavGraph graph;

  const ARNavigationPage({
    super.key,
    required this.scannedQrValue,
    required this.destinationNodeId,
    required this.graph,
  });

  @override
  State<ARNavigationPage> createState() => _ARNavigationPageState();
}

class _ARNavigationPageState extends State<ARNavigationPage> {
  ARSessionManager? _arSessionManager;
  ARObjectManager? _arObjectManager;
  ARAnchorManager? _arAnchorManager;
  ARLocationManager? _arLocationManager;

  late final NavigationSession _session;

  Timer? _frameTimer;
  ARNode? _avatarNode;

  bool _arReady = false;
  bool _initializingFlow = false;
  bool _navigationStarted = false;

  String _status = 'Opening AR...';
  String _distanceText = '';
  String _debugText = '';

  @override
  void initState() {
    super.initState();
    _session = NavigationSession(graph: widget.graph, arrivalThreshold: 0.8);
    DemoData.registerDemoAnchors(_session);

    _session.avatar.onDistanceUpdate = (distanceToNext, totalRemaining) {
      if (!mounted) return;
      setState(() {
        _distanceText =
            'Next: ${distanceToNext.toStringAsFixed(1)}m | Remaining: ${totalRemaining.toStringAsFixed(1)}m';
      });
    };

    _session.avatar.onArrived = () {
      if (!mounted) return;
      setState(() {
        _status = 'Arrived at destination';
      });
    };
  }

  void _onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    _arSessionManager = arSessionManager;
    _arObjectManager = arObjectManager;
    _arAnchorManager = arAnchorManager;
    _arLocationManager = arLocationManager;

    _arSessionManager!.onInitialize(
      showAnimatedGuide: true,
      showFeaturePoints: false,
      showPlanes: false,
      showWorldOrigin: false,
      handleTaps: false,
      handlePans: false,
      handleRotation: false,
    );

    _arObjectManager!.onInitialize();

    _initializeNavigationFlow();
  }

  Future<void> _initializeNavigationFlow() async {
    if (_initializingFlow) return;
    _initializingFlow = true;

    setState(() {
      _status = 'Waiting for valid camera pose... move the phone slowly';
    });

    final firstPose = await _waitForValidPose();
    if (!mounted) return;

    if (firstPose == null) {
      setState(() {
        _status = 'Camera pose is still unavailable.\nTry better light and slow motion.';
      });
      _initializingFlow = false;
      return;
    }

    setState(() {
      _arReady = true;
      _status = 'AR ready. Aligning from QR...';
    });

    final aligned = _session.onQRCodeScanned(widget.scannedQrValue, firstPose);

    if (!aligned) {
      setState(() {
        _status = 'Unknown QR code: ${widget.scannedQrValue}';
      });
      _initializingFlow = false;
      return;
    }

    final started = _session.navigateTo(widget.destinationNodeId, firstPose);

    if (!started) {
      setState(() {
        _status = 'Could not start navigation.\nCheck destination or alignment.';
      });
      _initializingFlow = false;
      return;
    }

    _navigationStarted = true;

    await _ensureAvatarNode();

    setState(() {
      _status = 'Navigation started';
    });

    _startFrameLoop();
    _initializingFlow = false;
  }

  Future<NavVector3?> _waitForValidPose({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final end = DateTime.now().add(timeout);

    while (mounted && DateTime.now().isBefore(end)) {
      final pose = await safeGetCameraPosition(_arSessionManager);
      if (pose != null) return pose;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<void> _ensureAvatarNode() async {
    if (_avatarNode != null || _arObjectManager == null) return;

    final avatarArPos = _session.avatar.avatarMapPosition != null
        ? _session.aligner.mapToAR(_session.avatar.avatarMapPosition!)
        : null;

    final startPos = avatarArPos ?? const NavVector3(0, 0, -1.5);

    final node = ARNode(
      type: NodeType.webGLB,
      uri:
          'https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Duck/glTF-Binary/Duck.glb',
      name: 'guide_avatar',
      position: startPos.toVm(),
      scale: vm.Vector3.all(0.2),
      rotation: vm.Vector4(1, 0, 0, 0),
    );

    final didAdd = await _arObjectManager!.addNode(node) ?? false;
    if (didAdd) {
      _avatarNode = node;
    } else {
      setState(() {
        _status = 'Navigation started, but avatar model could not be added';
      });
    }
  }

  void _startFrameLoop() {
    _frameTimer?.cancel();

    _frameTimer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
      final camPos = await safeGetCameraPosition(_arSessionManager);

      if (!mounted || camPos == null) {
        return;
      }

      final avatarArPos = _session.onARFrameUpdate(camPos);

      if (_avatarNode != null && avatarArPos != null) {
        _avatarNode!.position = avatarArPos.toVm();
      }

      if (mounted) {
        setState(() {
          _debugText = _session.debugInfo;
        });
      }
    });
  }

  Future<void> _restartNavigation() async {
    _frameTimer?.cancel();

    final camPos = await safeGetCameraPosition(_arSessionManager);
    if (camPos == null) {
      setState(() {
        _status = 'Camera pose not ready yet';
      });
      return;
    }

    final ok = _session.navigateTo(widget.destinationNodeId, camPos);
    if (!ok) {
      setState(() {
        _status = 'Navigation restart failed';
      });
      return;
    }

    await _ensureAvatarNode();

    setState(() {
      _status = 'Navigation restarted';
    });

    _startFrameLoop();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();

    try {
      if (_avatarNode != null) {
        _arObjectManager?.removeNode(_avatarNode!);
      }
    } catch (_) {}

    try {
      _arSessionManager?.dispose();
    } catch (_) {}

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canRestart = _arReady && _navigationStarted;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Navigation'),
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.none,
            showPlatformType: false,
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.white),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_status),
                      if (_distanceText.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(_distanceText),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        'QR: ${widget.scannedQrValue} | Destination: ${widget.destinationNodeId}',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_debugText.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _debugText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: canRestart ? _restartNavigation : null,
                            child: const Text('Restart nav'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => QRScannerPage(
                                    destinationNodeId: widget.destinationNodeId,
                                  ),
                                ),
                              );
                            },
                            child: const Text('Scan another QR'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------
/// 3) SAFE CAMERA POSE HELPER
/// ---------------------------

Future<NavVector3?> safeGetCameraPosition(
  ARSessionManager? arSessionManager,
) async {
  if (arSessionManager == null) return null;

  try {
    final vm.Matrix4? pose = await arSessionManager.getCameraPose();
    if (pose == null) return null;

    final vm.Vector3 translation = pose.getTranslation();
    return NavVector3(
      translation.x,
      translation.y,
      translation.z,
    );
  } on PlatformException catch (e) {
    if (e.code == 'NO_CAMERA_POSE') {
      return null;
    }
    rethrow;
  } catch (_) {
    return null;
  }
}

/// ---------------------------
/// 4) DEMO DATA
/// Replace this with your real JSON.
/// ---------------------------

class DemoData {
  static NavGraph buildGraph() {
    final mallJson = {
      'nodes': [
        {'id': 'door', 'x': 0, 'y': 0, 'z': 0, 'shopName': null},
        {'id': 'middle', 'x': 2, 'y': 0, 'z': 0, 'shopName': null},
        {'id': 'desk', 'x': 4, 'y': 0, 'z': 0, 'shopName': 'Desk'},
        {'id': 'bed', 'x': 2, 'y': 0, 'z': 3, 'shopName': 'Bed'},
      ],
      'edges': [
        {'from': 'door', 'to': 'middle'},
        {'from': 'middle', 'to': 'desk'},
        {'from': 'middle', 'to': 'bed'},
      ],
    };

    return NavGraph.fromJson(mallJson);
  }

  static void registerDemoAnchors(NavigationSession session) {
    session.registerQRAnchor('ROOM_DOOR', const NavVector3(0, 0, 0));
    session.registerQRAnchor('ROOM_MIDDLE', const NavVector3(2, 0, 0));
  }
}

/// ---------------------------
/// 5) NAVIGATION CORE
/// Adapted from your uploaded file.
/// ---------------------------

class NavVector3 {
  final double x;
  final double y;
  final double z;

  const NavVector3(this.x, this.y, this.z);

  double distanceTo(NavVector3 other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  NavVector3 operator -(NavVector3 other) =>
      NavVector3(x - other.x, y - other.y, z - other.z);

  NavVector3 operator +(NavVector3 other) =>
      NavVector3(x + other.x, y + other.y, z + other.z);

  factory NavVector3.fromJson(Map<String, dynamic> json) {
    return NavVector3(
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
      (json['z'] as num).toDouble(),
    );
  }

  vm.Vector3 toVm() => vm.Vector3(x, y, z);

  @override
  String toString() =>
      '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})';
}

class NavNode {
  final String id;
  final NavVector3 position;
  final String? shopName;

  const NavNode({
    required this.id,
    required this.position,
    this.shopName,
  });

  factory NavNode.fromJson(Map<String, dynamic> json) {
    return NavNode(
      id: json['id'] as String,
      position: NavVector3.fromJson(json),
      shopName: json['shopName'] as String?,
    );
  }
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

  factory NavEdge.fromJson(Map<String, dynamic> json) {
    return NavEdge(
      from: json['from'] as String,
      to: json['to'] as String,
      oneway: json['oneway'] as bool? ?? false,
      weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

class Neighbor {
  final String neighborId;
  final double cost;

  const Neighbor({
    required this.neighborId,
    required this.cost,
  });
}

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

      if (left < n && _heap[left].compareTo(_heap[smallest]) < 0) {
        smallest = left;
      }
      if (right < n && _heap[right].compareTo(_heap[smallest]) < 0) {
        smallest = right;
      }
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

class NavGraph {
  final Map<String, NavNode> nodes = {};
  final Map<String, List<Neighbor>> adjacency = {};

  NavGraph.fromJson(Map<String, dynamic> json) {
    for (final item in json['nodes'] as List) {
      final node = NavNode.fromJson(item as Map<String, dynamic>);
      nodes[node.id] = node;
      adjacency[node.id] = [];
    }

    for (final item in json['edges'] as List) {
      final edge = NavEdge.fromJson(item as Map<String, dynamic>);
      final distance =
          nodes[edge.from]!.position.distanceTo(nodes[edge.to]!.position);
      final cost = distance * edge.weight;

      adjacency[edge.from]!.add(Neighbor(neighborId: edge.to, cost: cost));
      if (!edge.oneway) {
        adjacency[edge.to]!.add(Neighbor(neighborId: edge.from, cost: cost));
      }
    }
  }

  List<NavNode>? findPath(String startId, String goalId) {
    if (!nodes.containsKey(startId) || !nodes.containsKey(goalId)) return null;
    if (startId == goalId) return [nodes[startId]!];

    final goalPos = nodes[goalId]!.position;
    final gScore = <String, double>{startId: 0.0};
    final cameFrom = <String, String>{};
    final closedSet = <String>{};

    final openSet = _MinHeap();
    openSet.add(startId, nodes[startId]!.position.distanceTo(goalPos));

    while (openSet.isNotEmpty) {
      final current = openSet.removeMin().nodeId;

      if (current == goalId) {
        return _reconstructPath(cameFrom, current);
      }

      if (closedSet.contains(current)) continue;
      closedSet.add(current);

      for (final neighbor in adjacency[current]!) {
        if (closedSet.contains(neighbor.neighborId)) continue;

        final tentativeG = gScore[current]! + neighbor.cost;

        if (tentativeG < (gScore[neighbor.neighborId] ?? double.infinity)) {
          cameFrom[neighbor.neighborId] = current;
          gScore[neighbor.neighborId] = tentativeG;

          final f = tentativeG +
              nodes[neighbor.neighborId]!.position.distanceTo(goalPos);

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
    double total = 0.0;
    for (int i = 0; i < path.length - 1; i++) {
      total += path[i].position.distanceTo(path[i + 1].position);
    }
    return total;
  }

  String findNearestNode(NavVector3 position) {
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

class CoordinateAligner {
  NavVector3? _offset;
  double _yawOffset = 0.0;

  bool get isAligned => _offset != null;

  void alignFromQRCode({
    required NavVector3 knownMapPosition,
    required NavVector3 arDetectedPosition,
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

  void forceAlignment({
    required NavVector3 knownMapPosition,
    required NavVector3 arPosition,
    double? mapYaw,
    double? arYaw,
  }) {
    _offset = arPosition - knownMapPosition;
    if (mapYaw != null && arYaw != null) {
      _yawOffset = arYaw - mapYaw;
    }
  }

  NavVector3? arToMap(NavVector3 arPosition) {
    if (_offset == null) return null;
    return arPosition - _offset!;
  }

  NavVector3? mapToAR(NavVector3 mapPosition) {
    if (_offset == null) return null;
    return mapPosition + _offset!;
  }
}

class QRAnchorRegistry {
  final Map<String, NavVector3> _anchors = {};

  void register(String qrValue, NavVector3 mapPosition) {
    _anchors[qrValue] = mapPosition;
  }

  NavVector3? lookup(String qrValue) => _anchors[qrValue];
}

enum NavigationState {
  waitingForAlignment,
  navigating,
  arrived,
  noPathFound,
}

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

    if (_path.isEmpty) {
      state = NavigationState.noPathFound;
      return;
    }

    if (_path.length == 1) {
      state = NavigationState.arrived;
      onDistanceUpdate?.call(0, 0);
      onArrived?.call();
      return;
    }

    _currentWaypointIndex = 1;
    state = NavigationState.navigating;

    if (onAvatarMoved != null) {
      onAvatarMoved!(_path[_currentWaypointIndex]);
    }
  }

  void update(NavVector3 userMapPosition) {
    if (state != NavigationState.navigating) return;

    if (_currentWaypointIndex >= _path.length) {
      state = NavigationState.arrived;
      onArrived?.call();
      return;
    }

    final targetWaypoint = _path[_currentWaypointIndex];
    final distanceToTarget = userMapPosition.distanceTo(targetWaypoint.position);
    final totalRemaining = _calculateRemainingDistance(userMapPosition);

    onDistanceUpdate?.call(distanceToTarget, totalRemaining);

    if (distanceToTarget < arrivalThreshold) {
      _currentWaypointIndex++;

      if (_currentWaypointIndex >= _path.length) {
        state = NavigationState.arrived;
        onArrived?.call();
        return;
      }

      onAvatarMoved?.call(_path[_currentWaypointIndex]);
    }
  }

  double _calculateRemainingDistance(NavVector3 userPosition) {
    if (_currentWaypointIndex >= _path.length) return 0.0;

    double remaining =
        userPosition.distanceTo(_path[_currentWaypointIndex].position);

    for (int i = _currentWaypointIndex; i < _path.length - 1; i++) {
      remaining += _path[i].position.distanceTo(_path[i + 1].position);
    }

    return remaining;
  }

  NavNode? get currentTarget =>
      (_currentWaypointIndex < _path.length) ? _path[_currentWaypointIndex] : null;

  NavVector3? get avatarMapPosition => currentTarget?.position;
}

class NavigationSession {
  final NavGraph graph;
  final CoordinateAligner aligner = CoordinateAligner();
  final QRAnchorRegistry qrRegistry = QRAnchorRegistry();
  final AvatarGuide avatar;

  String debugInfo = '';

  NavigationSession({
    required this.graph,
    double arrivalThreshold = 0.8,
  }) : avatar = AvatarGuide(arrivalThreshold: arrivalThreshold);

  void registerQRAnchor(String qrValue, NavVector3 mapPosition) {
    qrRegistry.register(qrValue, mapPosition);
  }

  bool onQRCodeScanned(String qrValue, NavVector3 arCameraPosition) {
    final mapPosition = qrRegistry.lookup(qrValue);

    if (mapPosition == null) {
      return false;
    }

    aligner.forceAlignment(
      knownMapPosition: mapPosition,
      arPosition: arCameraPosition,
    );

    return true;
  }

  void initializeDefaultAlignment(NavVector3 arCameraPosition) {
    aligner.forceAlignment(
      knownMapPosition: const NavVector3(0, 0, 0),
      arPosition: arCameraPosition,
    );
  }

  bool navigateTo(String destinationNodeId, NavVector3 currentARPosition) {
    final mapPos = aligner.arToMap(currentARPosition);
    if (mapPos == null) return false;

    final nearestNodeId = graph.findNearestNode(mapPos);
    final path = graph.findPath(nearestNodeId, destinationNodeId);

    if (path == null) {
      avatar.state = NavigationState.noPathFound;
      return false;
    }

    avatar.startNavigation(path);
    return true;
  }

  NavVector3? onARFrameUpdate(NavVector3 arCameraPosition) {
    final mapPos = aligner.arToMap(arCameraPosition);
    if (mapPos == null) return null;

    avatar.update(mapPos);

    debugInfo = 'AR: $arCameraPosition\n'
        'Map: $mapPos\n'
        'State: ${avatar.state}\n'
        'Target: ${avatar.currentTarget?.id ?? "none"}';

    if (avatar.avatarMapPosition != null) {
      return aligner.mapToAR(avatar.avatarMapPosition!);
    }

    return null;
  }
}
