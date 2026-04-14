import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'ar_navigation_system.dart';
// import 'ar_navigation_system.dart'; // Your existing logic file

class UniversalAvatarScreen extends StatefulWidget {
  final Map<String, dynamic> mallJson;

  const UniversalAvatarScreen({super.key, required this.mallJson});

  @override
  State<UniversalAvatarScreen> createState() => _UniversalAvatarScreenState();
}

class _UniversalAvatarScreenState extends State<UniversalAvatarScreen> {
  // Sensors & Camera
  CameraController? _cameraController;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double _currentHeading = 0; // The phone's orientation (0 = North)
  
  // Navigation Logic
  late NavigationSession _session;
  bool _isAligned = false;
  bool _isNavigating = false;
  
  // State
  String _status = "Initializing Sensors...";
  double _remainingDistance = 0;
  String _selectedShop = '';
  Vector3 _userSimulatedPos = Vector3(0, 0, 0); // User position from sensors

  @override
  void initState() {
    super.initState();
    // 1. Init your existing graph logic
    final graph = NavGraph.fromJson(widget.mallJson);
    _session = NavigationSession(graph: graph);
    _session.avatar.onArrived = _onArrived;
    _session.avatar.onDistanceUpdate = (dNext, dTotal) => setState(() => _remainingDistance = dTotal);

    // 2. Init Universal Sensors
    _initializeCamera();
    _initializeCompass();
  }

  // ───────────────────────────────
  // SENSOR INITIALIZATION
  // ───────────────────────────────
  
  void _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    
    _cameraController = CameraController(cameras[0], ResolutionPreset.medium, enableAudio: false);
    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  void _initializeCompass() {
    _compassSubscription = FlutterCompass.events!.listen((event) {
      if (!mounted) return;
      
      setState(() {
        _currentHeading = event.heading ?? 0;
        
        // Auto-align once sensors are stable
        if (!_isAligned) {
          // _session.initializeDefaultAlignment(Vector3(0, 0, 0));
          _isAligned = true;
          _status = "Scan a QR Code or Select Destination";
        }
        
        // --- THE NAVIGATION LOOP ---
        if (_isNavigating) {
          // Since Oppo A3 lacks PDR, we simulate movement for the demo
          // In real app, use pedometer steps to update _userSimulatedPos
          _simulateMovement(); 
          _session.onARFrameUpdate(_userSimulatedPos);
        }
      });
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _compassSubscription?.cancel();
    super.dispose();
  }

  // ───────────────────────────────
  // UI - UNIVERSAL AR LOOK
  // ───────────────────────────────
  
  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. The Real-world background (Standard Camera)
          CameraPreview(_cameraController!),
          
          // 2. Status Bar
          _buildStatusOverlay(),

          // 3. THE AVATAR (Center-Screen Overlay)
          if (_isNavigating && _session.avatar.currentTarget != null)
            _buildUniversalAvatarGuide(),

          // 4. Input UI
          if (_isAligned && !_isNavigating) _buildShopPicker(),
          if (_isNavigating) _buildNavStats(),
        ],
      ),
    );
  }

  // ───────────────────────────────
  // THE UNIVERSAL AVATAR VISUAL
  // ───────────────────────────────
  
  Widget _buildUniversalAvatarGuide() {
    // 1. Get the direction the avatar needs to go
    final targetNode = _session.avatar.currentTarget!;
    final targetPos = targetNode.position;
    
    // Calculate angle relative to the map origin (simplistic dead reckoning)
    double angleToTargetOnMap = atan2(targetPos.x - _userSimulatedPos.x, targetPos.z - _userSimulatedPos.z);
    
    // 2. Adjust for the phone's current heading
    double phoneHeadingRad = _currentHeading * (pi / 180);
    double avatarScreenRotation = angleToTargetOnMap + phoneHeadingRad;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The Walking Avatar Visual
          Transform.rotate(
            angle: avatarScreenRotation, // Point avatar towards next waypoint
            child: const Icon(
              Icons.directions_walk, // Use simple icon for Oppo A3 compatibility
              size: 150,
              color: Colors.greenAccent,
            ),
          ),
          
          // Indicator of next waypoint
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.black54,
            child: Text("Next: ${targetNode.id}", style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────
  // LOGIC & HELPERS
  // ───────────────────────────────

  void _simulateMovement() {
    // This is a crude simulation for testing on the Oppo A3
    // In production, use the pedometer and heading to update the Vector3
    double speed = 0.01; // meters per "frame"
    double headingRad = (_currentHeading) * (pi / 180);
    
    _userSimulatedPos = Vector3(
      _userSimulatedPos.x + (speed * sin(headingRad)),
      0, // Assume level floor
      _userSimulatedPos.z + (speed * cos(headingRad))
    );
  }

  void _onShopSelected(NavNode shop) {
    if (_session.navigateTo(shop.id, _userSimulatedPos)) {
      setState(() {
        _isNavigating = true;
        _selectedShop = shop.shopName!;
        _status = "Following Guide...";
      });
    }
  }

  void _onArrived() {
    setState(() {
      _isNavigating = false;
      _status = "You have arrived!";
    });
  }

  // UI Components
  Widget _buildStatusOverlay() {
    return Positioned(top: 50, left: 20, right: 20, child: Container(padding: const EdgeInsets.all(10), color: Colors.black54, child: Text(_status, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center)));
  }

  Widget _buildNavStats() {
    return Positioned(top: 100, left: 20, child: Card(color: Colors.black87, child: Padding(padding: const EdgeInsets.all(12), child: Text("${_remainingDistance.toStringAsFixed(1)}m", style: const TextStyle(color: Colors.white, fontSize: 24)))));
  }

  Widget _buildShopPicker() {
    final shops = _session.graph.nodes.values.where((n) => n.shopName != null).toList();
    return Positioned(bottom: 20, left: 10, right: 10, child: SizedBox(height: 100, child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: shops.length, itemBuilder: (ctx, i) => ActionChip(label: Text(shops[i].shopName!), onPressed: () => _onShopSelected(shops[i])))));
  }
}