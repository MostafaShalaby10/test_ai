// ══════════════════════════════════════════════════════════════════════════════
// main.dart
//
// Entry point with automatic device capability detection.
// Routes to the best navigation experience the device supports:
//
//   Tier 1 (fullAR)    → ar_navigation_screen.dart   (ARCore 3D avatar)
//   Tier 2 (sensorAR)  → sensor_ar_screen.dart       (Camera + compass arrow)
//   Tier 3 (map2D)     → map_2d_screen.dart          (2D floor plan)
// ══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';

import 'device_capability_checker.dart';
import 'ar_navigation_screen.dart';
import 'sensor_ar_screen.dart';
import 'map_2d_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MallNavigationApp());
}

class MallNavigationApp extends StatelessWidget {
  const MallNavigationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Mall Navigator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The detected device capability tier. Null while detecting.
  NavigationTier? _detectedTier;

  /// Whether detection is in progress.
  bool _isDetecting = true;

  /// Optional override — the user can manually pick a tier.
  NavigationTier? _overrideTier;

  @override
  void initState() {
    super.initState();
    _detectCapabilities();
  }

  Future<void> _detectCapabilities() async {
    setState(() => _isDetecting = true);

    final tier = await DeviceCapabilityChecker.detectTier();

    if (mounted) {
      setState(() {
        _detectedTier = tier;
        _isDetecting = false;
      });
    }
  }

  /// The tier that will actually be used (override or detected).
  NavigationTier get _activeTier =>
      _overrideTier ?? _detectedTier ?? NavigationTier.map2D;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Mall Navigator'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // ── Device Capability Card ──
            _buildCapabilityCard(),

            const SizedBox(height: 24),

            // ── Tier Override (for testing) ──
            _buildTierOverride(),

            const SizedBox(height: 24),

            // ── Start Button ──
            const Text(
              'Stand at the Entrance, then tap Start',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                icon: Icon(_tierIcon(_activeTier)),
                label: Text(
                  'Start ${DeviceCapabilityChecker.tierDescription(_activeTier)}',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _tierColor(_activeTier),
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 16),
                ),
                onPressed: _isDetecting
                    ? null
                    : () => _startNavigation(context),
              ),
            ),

            const Spacer(),

            // ── Info footer ──
            Text(
              'The app automatically detects your device capabilities\n'
              'and provides the best navigation experience possible.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════
  // CAPABILITY CARD — shows what was detected
  // ══════════════════════════════════════════════

  Widget _buildCapabilityCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _isDetecting
            ? const Row(
                children: [
                  CircularProgressIndicator(strokeWidth: 2),
                  SizedBox(width: 16),
                  Text('Detecting device capabilities...'),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _tierIcon(_detectedTier ?? NavigationTier.map2D),
                        color: _tierColor(_detectedTier ?? NavigationTier.map2D),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          DeviceCapabilityChecker.tierDescription(
                            _detectedTier ?? NavigationTier.map2D,
                          ),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _tierExplanation(_detectedTier!),
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
      ),
    );
  }

  // ══════════════════════════════════════════════
  // TIER OVERRIDE — for testing different tiers
  // ══════════════════════════════════════════════

  Widget _buildTierOverride() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Test different modes:',
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        const SizedBox(height: 8),
        Row(
          children: NavigationTier.values.map((tier) {
            final isActive = _activeTier == tier;
            final isDetected = tier == _detectedTier;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: isActive
                        ? _tierColor(tier).withOpacity(0.1)
                        : null,
                    side: BorderSide(
                      color: isActive ? _tierColor(tier) : Colors.grey[300]!,
                      width: isActive ? 2 : 1,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () {
                    setState(() {
                      _overrideTier = tier == _detectedTier ? null : tier;
                    });
                  },
                  child: Column(
                    children: [
                      Icon(_tierIcon(tier), size: 20, color: _tierColor(tier)),
                      const SizedBox(height: 4),
                      Text(
                        tier == NavigationTier.fullAR
                            ? 'Full AR'
                            : tier == NavigationTier.sensorAR
                            ? 'Sensor'
                            : '2D Map',
                        style: TextStyle(fontSize: 11, color: _tierColor(tier)),
                      ),
                      if (isDetected)
                        Text(
                          '(detected)',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════
  // NAVIGATION — routes to the correct screen
  // ══════════════════════════════════════════════

  void _startNavigation(BuildContext context) {
    Widget screen;

    switch (_activeTier) {
      case NavigationTier.fullAR:
        // Tier 1: Full ARCore/ARKit 3D navigation.
        screen = ARNavigationScreen(mallJson: _mallData, startNodeId: '1');
        break;

      case NavigationTier.sensorAR:
        // Tier 2: Camera + compass + step counter.
        screen = SensorARScreen(
          mallJson: _mallData,
          startNodeId: '1',
          initialFacingRadians: 0.0, // Facing +X direction at start
        );
        break;

      case NavigationTier.map2D:
        // Tier 3: 2D floor plan with turn-by-turn.
        screen = Map2DScreen(mallJson: _mallData, startNodeId: '1');
        break;
    }

    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  // ══════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════

  IconData _tierIcon(NavigationTier tier) {
    switch (tier) {
      case NavigationTier.fullAR:
        return Icons.view_in_ar;
      case NavigationTier.sensorAR:
        return Icons.sensors;
      case NavigationTier.map2D:
        return Icons.map;
    }
  }

  Color _tierColor(NavigationTier tier) {
    switch (tier) {
      case NavigationTier.fullAR:
        return Colors.blue;
      case NavigationTier.sensorAR:
        return Colors.orange;
      case NavigationTier.map2D:
        return Colors.green;
    }
  }

  String _tierExplanation(NavigationTier tier) {
    switch (tier) {
      case NavigationTier.fullAR:
        return 'Your device supports ARCore! You\'ll get the full 3D AR experience '
            'with a virtual avatar guiding you through the mall.';
      case NavigationTier.sensorAR:
        return 'Your device has compass and motion sensors but doesn\'t support ARCore. '
            'You\'ll see the camera with a direction arrow overlay and step-by-step guidance.';
      case NavigationTier.map2D:
        return 'Your device doesn\'t have the sensors needed for AR. '
            'You\'ll get a clear 2D map with turn-by-turn directions.';
    }
  }

  // ══════════════════════════════════════════════
  // MALL DATA (shared across all tiers)
  // ══════════════════════════════════════════════

  static final Map<String, dynamic> _mallData = {
    "nodes": [
      {
        "id": "1",
        "name": "Entrance",
        "x": 0,
        "y": 0,
        "z": 0,
        "shopName": "store",
      },
      {
        "id": "2",
        "name": "stairs",
        "x": 1,
        "y": 2, // Floor 2
        "z": 0,
        "shopName": "stairs",
      },
      {
        "id": "3",
        "name": "stairs",
        "x": 1,
        "y": 2, // Floor 2
        "z": 1,
        "shopName": "stairs",
      },
      {
        "id": "4",
        "name": "Zara",
        "x": 5,
        "y": 0,
        "z": 0,
        "shopName": "store",
      },
      {
        "id": "8",
        "name": "Midpoint",
        "x": 5,
        "y": 0,
        "z": 2,
        "shopName": "store",
      },
      {
        "id": "5",
        "name": "Nike",
        "x": 5,
        "y": 0,
        "z": 4,
        "shopName": "store",
      },
      {
        "id": "6",
        "name": "adidas",
        "x": 5,
        "y": 2,
        "z": 0,
        "shopName": "store",
      },
      {
        "id": "7",
        "name": "resturant",
        "x": 5,
        "y": 2,
        "z": 4,
        "shopName": "store",
      },
    ],
    "edges": [
      {"from": "1", "to": "2"},
      {"from": "2", "to": "3"},
      {"from": "1", "to": "4"},
      {"from": "4", "to": "8"},
      {"from": "8", "to": "5"},
      {"from": "3", "to": "6"},
      {"from": "3", "to": "7"},
    ],
  };
}
