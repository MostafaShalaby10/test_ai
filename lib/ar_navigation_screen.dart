import 'dart:developer';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'ar_navigation_system.dart';
import 'camera_intrinsics.dart';
import 'isolate_localizer.dart';
import 'localization_service.dart';
import 'mall_data.dart';
import 'mall_geometry.dart' as geom;

enum _ARPhase {
  pickingDestination,
  pickingStartingShop,
  scanning,
  navigating,
  arrived,
}

class ARNavigationScreen extends StatefulWidget {
  final MallData mall;
  const ARNavigationScreen({super.key, required this.mall});
  @override
  State<ARNavigationScreen> createState() => _ARNavigationScreenState();
}

class _ARNavigationScreenState extends State<ARNavigationScreen> {
  late ARSessionManager arSessionManager;
  late ARObjectManager arObjectManager;
  late final NavigationSession _session;

  bool _isARReady = false;
  String _debugText = '';
  double _remainingDistance = 0;
  // Screen-space rotation of the directional arrow, in radians.
  // 0 = target ahead, positive = target to the right, ±π = target behind.
  double _arrowRadians = 0;

  _ARPhase _phase = _ARPhase.pickingDestination;
  NavNode? _destination;
  Shop? _startingShop;
  vm.Matrix4? _latestPose;

  // Per-frame bearing telemetry (rate-limited to avoid log spam).
  DateTime _lastBearingLog = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastBearingDebug = '';

  final IsolateLocalizer _localizer = IsolateLocalizer();
  bool _scanning = false;
  String _scanStatus = '';
  Color _scanStatusColor = Colors.blueGrey;

  @override
  void initState() {
    super.initState();
    log('initState: nodes=${widget.mall.navigationGraph.nodes.length}',
        name: 'AR');
    _session = NavigationSession(graph: widget.mall.navigationGraph);
    _session.avatar.onAvatarMoved = _onAvatarMoved;
    _session.avatar.onArrived = _onArrived;
    _session.avatar.onDistanceUpdate = _onDistanceUpdate;
    _localizer.spawn();
  }

  @override
  void dispose() {
    _localizer.dispose();
    arSessionManager.dispose();
    super.dispose();
  }

  List<Shop> _scannableShops() => widget.mall.shops.values
      .where((s) => s.featureFile != null)
      .toList();

  // Align the map frame to the AR frame from a *visual fix* of the chosen
  // starting shop's sign. The localizer recovers the camera's mall-frame
  // position and heading by matching ORB features in the snapshot against
  // the shop's surveyed reference, so we no longer have to assume the user
  // is exactly at the doorstep facing the sign.
  void _alignFromVisualFix(
      vm.Matrix4 currentPose, Vector3 mallPosition, double mallHeadingDeg) {
    final firstARPos = Vector3(currentPose.getColumn(3).x,
        currentPose.getColumn(3).y, currentPose.getColumn(3).z);
    final backCol = currentPose.getColumn(2); // camera +Z in world = back
    final arCameraYaw = math.atan2(backCol.z, -backCol.x);
    // mallHeadingDeg is the mall direction the camera was pointing at scan
    // time — that IS the user's heading, no `+180°` correction needed.
    final knownMapYawRad = geom.degToRad(mallHeadingDeg);
    _session.aligner.alignFromQRCode(
      knownMapPosition: mallPosition,
      arDetectedPosition: firstARPos,
      arCameraYaw: arCameraYaw,
      knownMapYaw: knownMapYawRad,
    );
    log('Aligned from visual fix: AR $firstARPos → mall $mallPosition, '
        'camYaw=${arCameraYaw.toStringAsFixed(3)} rad, '
        'mallHeading=${mallHeadingDeg.toStringAsFixed(1)}°', name: 'AR');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      ARView(onARViewCreated: _onARViewCreated, planeDetectionConfig: PlaneDetectionConfig.horizontal),
      _buildStatusBar(),
      if (_phase == _ARPhase.navigating) _buildArrowOverlay(),
      _buildDebugOverlay(),
      if (_isARReady && _phase == _ARPhase.pickingDestination) _buildDestinationPicker(),
      if (_isARReady && _phase == _ARPhase.pickingStartingShop) _buildStartingShopPicker(),
      if (_phase == _ARPhase.scanning) _buildScanPrompt(),
      if (_phase == _ARPhase.scanning) _buildShutter(),
      if (_phase == _ARPhase.navigating) _buildNavigationInfo(),
      if (_phase == _ARPhase.arrived) _buildArrivalOverlay(),
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
          _latestPose = pose;
          final arPos = Vector3(pose.getColumn(3).x, pose.getColumn(3).y, pose.getColumn(3).z);
          if (!_isARReady) {
            setState(() => _isARReady = true);
            log('★ AR tracking started. First pose: $arPos', name: 'AR');
          }
          // Avatar + arrow are only meaningful once we've aligned (i.e. after
          // the user picks a starting shop). Before then, we just track the
          // camera pose for use at alignment time.
          if (_phase == _ARPhase.navigating) {
            final avatarARPos = _session.onARFrameUpdate(arPos);
            if (avatarARPos != null) {
              _updateAvatarModel(avatarARPos);
              // Bearing from camera forward to target. We use ONLY the
              // forward direction from the pose (column 2 = back, so
              // forward = -col2). We do NOT use column 0 (camera-local +X)
              // for "right" because ARKit's camera-local axes are oriented
              // to the device sensor — in portrait mode the sensor's +X
              // points along the long edge of the device, i.e. roughly +Y
              // in world (vertical), not user-right. Its xz projection is
              // garbage. Instead, derive user-right from the forward
              // direction projected to the floor: right = forward × up
              // where up = +Y. In xz that's (right.x, right.z) =
              // (-fwd.z, fwd.x). And the forward xz projection must be
              // normalised so a pitched phone (looking at the floor while
              // walking) doesn't shrink the forward component and bias the
              // bearing toward ±90°.
              final backCol = pose.getColumn(2);
              final fwdXRaw = -backCol.x;
              final fwdZRaw = -backCol.z;
              final fwdLen = math.sqrt(fwdXRaw * fwdXRaw + fwdZRaw * fwdZRaw);
              final fwdX = fwdLen > 1e-6 ? fwdXRaw / fwdLen : 1.0;
              final fwdZ = fwdLen > 1e-6 ? fwdZRaw / fwdLen : 0.0;
              final rightX = -fwdZ;
              final rightZ = fwdX;
              final dX = avatarARPos.x - arPos.x;
              final dZ = avatarARPos.z - arPos.z;
              final forwardComp = dX * fwdX + dZ * fwdZ;
              final rightComp = dX * rightX + dZ * rightZ;
              final targetBearing = math.atan2(rightComp, forwardComp);
              // Low-pass filter toward the target bearing using the shortest
              // angular path. Without this, waypoint advances and sensor noise
              // cause the arrow to snap/stutter. 0.2 factor = ~150 ms settle.
              double delta = targetBearing - _arrowRadians;
              while (delta > math.pi) delta -= 2 * math.pi;
              while (delta < -math.pi) delta += 2 * math.pi;
              _arrowRadians += delta * 0.2;

              // Per-frame telemetry — both on screen (every frame) and in
              // logs (throttled to ~1Hz). Lets us see whether the arrow is
              // pointing where we'd expect for the user's actual orientation
              // and position.
              final fwdYawRad = math.atan2(-backCol.z, -backCol.x);
              final mapPos = _session.aligner.arToMap(arPos);
              final tgtBearDeg = (targetBearing * 180 / math.pi);
              final smoothBearDeg = (_arrowRadians * 180 / math.pi);
              _lastBearingDebug =
                  'arPos=(${arPos.x.toStringAsFixed(2)}, ${arPos.z.toStringAsFixed(2)})\n'
                  'mapPos=(${mapPos?.x.toStringAsFixed(2) ?? "?"}, ${mapPos?.z.toStringAsFixed(2) ?? "?"})\n'
                  'avatarAR=(${avatarARPos.x.toStringAsFixed(2)}, ${avatarARPos.z.toStringAsFixed(2)})\n'
                  'd=(${dX.toStringAsFixed(2)}, ${dZ.toStringAsFixed(2)}) '
                  'fwd=${forwardComp.toStringAsFixed(2)} right=${rightComp.toStringAsFixed(2)}\n'
                  'fwdYaw=${(fwdYawRad * 180 / math.pi).toStringAsFixed(0)}° '
                  'tgtBrg=${tgtBearDeg.toStringAsFixed(0)}° '
                  'smooth=${smoothBearDeg.toStringAsFixed(0)}°';
              final now = DateTime.now();
              if (now.difference(_lastBearingLog).inMilliseconds >= 1000) {
                log(_lastBearingDebug.replaceAll('\n', ' | '), name: 'AR.NAV');
                _lastBearingLog = now;
              }
            }
            if (mounted) setState(() {
              _debugText = '${_session.debugInfo}\n$_lastBearingDebug';
            });
          }
        }
      } catch (e) {
        if (mounted) setState(() { _debugText = 'Waiting for AR...\n${e.toString().split(",").first}'; });
      }
      _startFrameUpdates();
    });
  }

  // Phase 1 → 2: destination picked.
  void _onDestinationSelected(NavNode dest) {
    log('Destination selected: ${dest.id} "${dest.shopName}"', name: 'AR');
    setState(() {
      _destination = dest;
      _phase = _ARPhase.pickingStartingShop;
    });
  }

  // Phase 2 → 3: starting shop picked. Don't align yet — transition to a
  // scanning phase so the user can take a photo of the sign and we can
  // recover their precise position + heading via solvePnP.
  void _onStartingShopSelected(Shop shop) {
    log('Starting shop: "${shop.name}" (${shop.id})', name: 'AR');
    setState(() {
      _startingShop = shop;
      _phase = _ARPhase.scanning;
      _scanStatus = 'Point at the ${shop.name} sign and tap shutter';
      _scanStatusColor = Colors.blue;
    });
  }

  // Phase 3 → 4: visual scan succeeded. Align AR using the precise mall
  // position + heading from the localizer, then kick off A* navigation.
  Future<void> _onShutterPressed() async {
    if (_scanning) return;
    final shop = _startingShop;
    final pose = _latestPose;
    final dest = _destination;
    if (shop == null || pose == null || dest == null) {
      _setScanStatus('AR not ready yet', Colors.orange);
      return;
    }

    setState(() {
      _scanning = true;
      _scanStatus = 'Scanning ${shop.name}...';
      _scanStatusColor = Colors.blue;
    });

    try {
      // 1. Snapshot bytes from AR session (PNG of the rendered SCNView).
      //    cv.imdecode auto-detects PNG vs JPEG, so this drops in to the
      //    same localizer pipeline Tier 2 uses.
      final imgProvider = await arSessionManager.snapshot();
      final bytes = (imgProvider as MemoryImage).bytes;

      // 2. Get intrinsics for the snapshot. Prefer ARKit's actual projection
      //    matrix (true FOV + correct device orientation + aspect cropping)
      //    over the FOV-estimated fallback. The fallback misjudged FOV by
      //    5–10° on this device, biasing solvePnP into sign-flipped poses
      //    and bad headings.
      final arIntrinsics = await ARIntrinsicsChannel.fetchSnapshotIntrinsics();
      final CameraIntrinsics intrinsics;
      if (arIntrinsics != null) {
        intrinsics = arIntrinsics;
        log('Using ARKit intrinsics: $arIntrinsics', name: 'AR');
      } else {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        intrinsics = CameraIntrinsics.estimatedFromFov(
          width: frame.image.width,
          height: frame.image.height,
        );
        frame.image.dispose();
        log('AR intrinsics unavailable — using FOV fallback: $intrinsics',
            name: 'AR');
      }

      // 3. Run the same ORB → solvePnP pipeline Tier 2 uses.
      final features = await widget.mall.loadFeaturesForShop(shop.id);
      final result = await _localizer.localize(
        jpegBytes: bytes,
        target: features,
        shopData: shop,
        intrinsics: intrinsics,
      );

      if (!mounted) return;
      if (!result.isSuccess) {
        _setScanStatus(
            '✗ ${failReasonHumanMessage(result.failReason!)}', Colors.red);
        return;
      }

      // 4. Align using the precise visual fix. With true ARKit intrinsics
      // the visual heading is reliable (matches Tier 2 numbers); only fall
      // back to the facingAngle + 180° assumption if we had to estimate
      // intrinsics from FOV (in which case the heading can be 30–50° off).
      final mallPos = result.mallPosition!;
      final visualHeading = result.mallHeadingDeg!;
      final assumedHeading = geom.normalizeAngle(shop.facingAngle + 180.0);
      final mallHeading = arIntrinsics != null ? visualHeading : assumedHeading;
      log('Heading: visual=${visualHeading.toStringAsFixed(1)}°, '
          'assumed=${assumedHeading.toStringAsFixed(1)}°, '
          'using=${mallHeading.toStringAsFixed(1)}° '
          '(${arIntrinsics != null ? "true intrinsics → trust visual" : "FOV fallback → trust assumed"})',
          name: 'AR');
      _alignFromVisualFix(pose, mallPos, mallHeading);

      // 5. Build the path and start avatar navigation.
      final arPos = Vector3(
          pose.getColumn(3).x, pose.getColumn(3).y, pose.getColumn(3).z);
      final success = _session.navigateTo(dest.id, arPos);
      log('navigateTo result: $success', name: 'AR');
      if (success) {
        setState(() {
          _phase = _ARPhase.navigating;
          _scanStatus =
              '✓ Fix at ${shop.name} (${result.inlierCount}/${result.goodMatchCount})';
          _scanStatusColor = Colors.green;
        });
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No path found.'), backgroundColor: Colors.red));
      }
    } catch (e, st) {
      log('Scan error: $e\n$st', name: 'AR');
      if (mounted) _setScanStatus('Scan error: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _setScanStatus(String msg, Color color) {
    setState(() {
      _scanStatus = msg;
      _scanStatusColor = color;
    });
  }

  void _resetForNewNavigation() {
    setState(() {
      _phase = _ARPhase.pickingDestination;
      _destination = null;
      _startingShop = null;
      _scanStatus = '';
      _session.avatar.state = NavigationState.waitingForAlignment;
    });
  }

  void _updateAvatarModel(Vector3 arPos) {
    // TODO: Place 3D model at arPos
  }

  void _onAvatarMoved(NavNode wp) {
    log('Avatar moved to: ${wp.id} ${wp.position}', name: 'AR');
    final arPos = _session.aligner.mapToAR(wp.position);
    if (arPos != null) _updateAvatarModel(arPos);
  }

  void _onArrived() {
    log('★ ARRIVED!', name: 'AR');
    setState(() => _phase = _ARPhase.arrived);
  }
  void _onDistanceUpdate(double d, double t) { setState(() { _remainingDistance = t; }); }

  // ── UI ──
  Widget _buildStatusBar() {
    String text;
    Color bg;
    if (!_isARReady) {
      text = '⏳ Initializing AR...';
      bg = Colors.grey;
    } else if (_phase == _ARPhase.navigating) {
      text = '🚶 Navigating to ${_destination?.shopName ?? ""}';
      bg = Colors.blue;
    } else if (_phase == _ARPhase.scanning) {
      text = _scanning ? '⌛ $_scanStatus' : '📷 $_scanStatus';
      bg = _scanStatusColor;
    } else if (_phase == _ARPhase.pickingStartingShop) {
      text = '📍 Pick where you are standing';
      bg = Colors.deepOrange;
    } else {
      text = '✅ Ready — pick a destination';
      bg = Colors.green;
    }
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8, left: 16, right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

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

  Widget _buildDebugOverlay() => Positioned(bottom: _phase == _ARPhase.navigating ? 120 : 200, left: 8,
    child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Text(_debugText, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'))));

  // Phase 1 — pick destination from any shopName-bridged graph node.
  Widget _buildDestinationPicker() {
    final destinations = _session.graph.nodes.values
        .where((n) => n.shopName != null)
        .toList();
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)]),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Step 1 of 2', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        const Text('Where do you want to go?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: destinations.map((s) => ElevatedButton.icon(icon: const Icon(Icons.store), label: Text(s.shopName!), onPressed: () => _onDestinationSelected(s))).toList()),
      ])));
  }

  // Phase 2 — pick the shop the user is standing at (only those with
  // feature files; their doorstep + facingAngle anchor the AR alignment).
  Widget _buildStartingShopPicker() {
    final scannable = _scannableShops();
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)]),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Step 2 of 2', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text('Going to ${_destination?.shopName ?? ""}', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        const SizedBox(height: 8),
        const Text('Which shop are you standing at?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        if (scannable.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'No surveyed shops found. Run sign_surveyor and '
              'scripts/sync_mall_assets.sh.',
              style: TextStyle(fontSize: 13, color: Colors.red[700]),
            ),
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: scannable.map((s) => ElevatedButton.icon(icon: const Icon(Icons.store), label: Text(s.name), onPressed: () => _onStartingShopSelected(s))).toList()),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() {
            _phase = _ARPhase.pickingDestination;
            _destination = null;
            _startingShop = null;
          }),
          child: const Text('← Change destination'),
        ),
      ])));
  }

  Widget _buildNavigationInfo() => Positioned(bottom: 0, left: 0, right: 0,
    child: Container(padding: const EdgeInsets.all(20), decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${_remainingDistance.toStringAsFixed(0)}m', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          Text('to ${_destination?.shopName ?? ""}', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
        ]),
        const Spacer(),
        TextButton(onPressed: _resetForNewNavigation, child: const Text('Cancel', style: TextStyle(color: Colors.red))),
      ])));

  // Phase 3 — banner above the live AR view while the user lines up the shot.
  Widget _buildScanPrompt() {
    final shop = _startingShop;
    return Positioned(
      bottom: 0, left: 0, right: 0,
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
            Text('Going to ${_destination?.shopName ?? ""}',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 4),
            Text(
              shop == null
                  ? 'Pick where you are first'
                  : 'Point at the ${shop.name} sign and tap shutter',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _phase = _ARPhase.pickingStartingShop;
                _startingShop = null;
              }),
              child: const Text('← Change starting shop'),
            ),
            const SizedBox(height: 80), // room for shutter
          ],
        ),
      ),
    );
  }

  Widget _buildShutter() {
    return Positioned(
      bottom: 130, left: 0, right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _scanning ? null : _onShutterPressed,
          child: Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _scanning ? Colors.grey : Colors.white,
              border: Border.all(color: Colors.black54, width: 4),
            ),
            child: _scanning
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : const Icon(Icons.center_focus_strong,
                    color: Colors.black, size: 36),
          ),
        ),
      ),
    );
  }

  Widget _buildArrivalOverlay() => Positioned.fill(child: Container(color: Colors.black54, child: Center(child: Container(
    padding: const EdgeInsets.all(32), margin: const EdgeInsets.all(40), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle, color: Colors.green, size: 80), const SizedBox(height: 16),
      const Text('You Have Arrived!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      Text(_destination?.shopName ?? '', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
      const SizedBox(height: 24),
      ElevatedButton(onPressed: _resetForNewNavigation, child: const Text('Navigate Somewhere Else')),
    ])))));
}
