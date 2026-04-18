import 'dart:math' as math;
import 'dart:developer';
import 'package:flutter/material.dart';
import 'ar_navigation_system.dart';

class Map2DScreen extends StatefulWidget {
  final Map<String, dynamic> mallJson;
  final String startNodeId;
  const Map2DScreen({super.key, required this.mallJson, required this.startNodeId});
  @override
  State<Map2DScreen> createState() => _Map2DScreenState();
}

class _Map2DScreenState extends State<Map2DScreen> with SingleTickerProviderStateMixin {
  late NavGraph _graph;
  List<NavNode>? _path;
  int _wpIdx = 0;
  bool _isNav = false;
  bool _arrived = false;
  String _shop = '';
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    log('initState: start=${widget.startNodeId}', name: 'MAP2D');
    _graph = NavGraph.fromJson(widget.mallJson);
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 8, end: 14).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _pulseCtrl.dispose(); super.dispose(); }

  void _onDest(NavNode shop) {
    log('Destination: "${shop.shopName}" (${shop.id})', name: 'MAP2D');
    final path = _graph.findPath(widget.startNodeId, shop.id);
    if (path == null) { log('No path!', name: 'MAP2D'); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No path found.'), backgroundColor: Colors.red)); return; }
    log('Path: ${path.map((n) => n.id).join(" → ")}', name: 'MAP2D');
    setState(() { _path = path; _wpIdx = 0; _isNav = true; _shop = shop.shopName ?? shop.id; _arrived = false; });
  }

  void _advance() {
    log('Advance: $_wpIdx → ${_wpIdx + 1}', name: 'MAP2D');
    setState(() { _wpIdx++; if (_wpIdx >= _path!.length - 1) { _arrived = true; _isNav = false; log('★ ARRIVED', name: 'MAP2D'); } });
  }

  String _getDir(NavNode from, NavNode to) {
    final dx = to.position.x - from.position.x, dz = to.position.z - from.position.z, dy = to.position.y - from.position.y;
    final dist = from.position.distanceTo(to.position);
    if (dy.abs() > 1.0) return dy > 0 ? 'Go UP (${dist.toStringAsFixed(0)}m)' : 'Go DOWN (${dist.toStringAsFixed(0)}m)';
    final a = math.atan2(dz, dx) * 180 / math.pi;
    String d;
    if (a > -22.5 && a <= 22.5) d = 'right'; else if (a > 22.5 && a <= 67.5) d = 'forward-right'; else if (a > 67.5 && a <= 112.5) d = 'forward'; else if (a > 112.5 && a <= 157.5) d = 'forward-left'; else if (a > 157.5 || a <= -157.5) d = 'left'; else if (a > -157.5 && a <= -112.5) d = 'back-left'; else if (a > -112.5 && a <= -67.5) d = 'backward'; else d = 'back-right';
    return 'Walk $d toward ${to.shopName ?? to.id} (${dist.toStringAsFixed(0)}m)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('2D Map Navigation'), backgroundColor: Colors.orange, foregroundColor: Colors.white, actions: [
        if (_isNav) TextButton(onPressed: () => setState(() { _isNav = false; _path = null; }), child: const Text('Cancel', style: TextStyle(color: Colors.white)))]),
      body: Column(children: [
        Container(width: double.infinity, padding: const EdgeInsets.all(8), color: Colors.orange[50], child: const Text('📍 2D Map Mode', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.orange))),
        Expanded(flex: 3, child: AnimatedBuilder(animation: _pulseAnim, builder: (c, _) => CustomPaint(painter: MapPainter(graph: _graph, path: _path, currentWaypointIndex: _wpIdx, userDotRadius: _pulseAnim.value), size: Size.infinite))),
        if (!_isNav && !_arrived) _buildPicker(),
        if (_isNav) _buildDirs(),
        if (_arrived) _buildArrival(),
      ]));
  }

  Widget _buildPicker() {
    final shops = _graph.nodes.values.where((n) => n.shopName != null && n.id != widget.startNodeId).toList();
    return Container(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('You are at: ${widget.startNodeId}', style: TextStyle(color: Colors.grey[600])),
      const SizedBox(height: 8), const Text('Where do you want to go?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: shops.map((s) => ElevatedButton.icon(icon: const Icon(Icons.store), label: Text(s.shopName!), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), onPressed: () => _onDest(s))).toList()),
    ]));
  }

  Widget _buildDirs() {
    if (_path == null || _wpIdx >= _path!.length - 1) return const SizedBox.shrink();
    final cur = _path![_wpIdx], nxt = _path![_wpIdx + 1];
    final dir = _getDir(cur, nxt);
    final totalDist = _graph.pathDistance(_path!.sublist(_wpIdx));
    return Container(padding: const EdgeInsets.all(16), decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.grey, width: 0.5))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.directions_walk, color: Colors.white, size: 28)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dir, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('${totalDist.toStringAsFixed(0)}m remaining to $_shop', style: TextStyle(color: Colors.grey[600])),
            Text('Step ${_wpIdx + 1} of ${_path!.length - 1}', style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          ])),
        ]),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(icon: const Icon(Icons.check), label: const Text("I'm here — next step"),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)), onPressed: _advance)),
      ]));
  }

  Widget _buildArrival() => Container(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.check_circle, color: Colors.green, size: 60), const SizedBox(height: 12),
    const Text('You Have Arrived!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    Text(_shop, style: TextStyle(fontSize: 16, color: Colors.grey[600])), const SizedBox(height: 16),
    ElevatedButton(onPressed: () => setState(() { _arrived = false; _path = null; }), child: const Text('Navigate Somewhere Else')),
  ]));
}

class MapPainter extends CustomPainter {
  final NavGraph graph;
  final List<NavNode>? path;
  final int currentWaypointIndex;
  final double userDotRadius;
  final Vector3? userPosition;
  final double? userHeading;
  final double? padding;
  final double scaleFactor;

  MapPainter({
    required this.graph,
    this.path,
    this.currentWaypointIndex = 0,
    this.userDotRadius = 10,
    this.userPosition,
    this.userHeading,
    this.padding,
    this.scaleFactor = 1.0,
  });

  @override
  void paint(Canvas c, Size size) {
    double mnX = double.infinity, mxX = double.negativeInfinity, mnZ = double.infinity, mxZ = double.negativeInfinity;
    for (final n in graph.nodes.values) { mnX = math.min(mnX, n.position.x); mxX = math.max(mxX, n.position.x); mnZ = math.min(mnZ, n.position.z); mxZ = math.max(mxZ, n.position.z); }
    final pad = padding ?? math.min(size.width, size.height) * 0.1;
    final mw = mxX - mnX, mh = mxZ - mnZ;
    final baseSc = math.min((size.width - pad * 2) / (mw == 0 ? 1 : mw), (size.height - pad * 2) / (mh == 0 ? 1 : mh));
    final sc = baseSc * scaleFactor;
    
    final mapPixelW = mw * sc;
    final mapPixelH = mh * sc;
    
    double ox = (size.width - mapPixelW) / 2;
    double oz = (size.height - mapPixelH) / 2;

    if (userPosition != null && scaleFactor >= 1.0) {
       final relX = mw == 0 ? 0.5 : (userPosition!.x - mnX) / mw;
       final relZ = mh == 0 ? 0.5 : (userPosition!.z - mnZ) / mh;
       final userPxlX = relX * mapPixelW;
       final userPxlZ = relZ * mapPixelH;
       ox = (size.width / 2) - userPxlX;
       oz = (size.height / 2) - userPxlZ;
    }
    
    Offset ts(Vector3 p) => Offset(ox + (p.x - mnX) * sc, oz + (p.z - mnZ) * sc);

    final ep = Paint()..color = Colors.grey[300]!..strokeWidth = 2..style = PaintingStyle.stroke;
    for (final nid in graph.adjacency.keys) { final f = graph.nodes[nid]!; for (final nb in graph.adjacency[nid]!) { c.drawLine(ts(f.position), ts(graph.nodes[nb.neighborId]!.position), ep); } }

    if (path != null && path!.length > 1) {
      final pp = Paint()..color = Colors.orange..strokeWidth = 5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
      for (int i = currentWaypointIndex; i < path!.length - 1; i++) c.drawLine(ts(path![i].position), ts(path![i + 1].position), pp);
      final cp = Paint()..color = Colors.orange.withOpacity(0.3)..strokeWidth = 4..style = PaintingStyle.stroke;
      for (int i = 0; i < currentWaypointIndex && i < path!.length - 1; i++) c.drawLine(ts(path![i].position), ts(path![i + 1].position), cp);
      final dp = ts(path!.last.position);
      c.drawCircle(dp, 12, Paint()..color = Colors.red);
      c.drawCircle(dp, 6, Paint()..color = Colors.white);
    }

    for (final n in graph.nodes.values) {
      final p = ts(n.position);
      final isS = n.shopName != null;
      c.drawCircle(p, isS ? 6 : 3, Paint()..color = isS ? Colors.blue[700]! : Colors.grey[400]!);
      
      final label = n.shopName ?? n.id;
      final tp = TextPainter(
        text: TextSpan(
          text: label, 
          style: TextStyle(
            fontSize: isS ? 11 : 9, 
            color: isS ? Colors.blue[900] : Colors.black87, 
            fontWeight: isS ? FontWeight.bold : FontWeight.normal
          )
        ), 
        textDirection: TextDirection.ltr
      )..layout();
      tp.paint(c, Offset(p.dx - tp.width / 2, p.dy + (isS ? 8 : 4)));
    }

    Vector3? drawPos;
    if (userPosition != null) {
      drawPos = userPosition;
    } else if (path != null && currentWaypointIndex < path!.length) {
      drawPos = path![currentWaypointIndex].position;
    }

    if (drawPos != null) {
      final up = ts(drawPos);
      c.drawCircle(up, userDotRadius + 4, Paint()..color = Colors.blue.withOpacity(0.3));
      
      if (userHeading != null) {
        final headingPaint = Paint()
          ..color = Colors.blue.withOpacity(0.8)
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        final dx = math.cos(userHeading!);
        final dz = math.sin(userHeading!);
        final length = userDotRadius + 12;
        c.drawLine(up, Offset(up.dx + dx * length, up.dy + dz * length), headingPaint);
      }
      
      c.drawCircle(up, 8, Paint()..color = Colors.blue);
      c.drawCircle(up, 4, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter o) => o.currentWaypointIndex != currentWaypointIndex || o.userDotRadius != userDotRadius || o.path != path || o.userPosition != userPosition || o.userHeading != userHeading;
}
