import 'dart:developer';
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
  Widget build(BuildContext context) => MaterialApp(
    title: 'AR Mall Navigator',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  NavigationTier? _detected;
  bool _detecting = true;
  NavigationTier? _override;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    log('Starting capability detection...', name: 'MAIN');
    setState(() => _detecting = true);
    final tier = await DeviceCapabilityChecker.detectTier();
    log(
      'Detected tier: $tier (${DeviceCapabilityChecker.tierDescription(tier)})',
      name: 'MAIN',
    );
    if (mounted)
      setState(() {
        _detected = tier;
        _detecting = false;
      });
  }

  NavigationTier get _active => _override ?? _detected ?? NavigationTier.map2D;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Mall Navigator'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            _buildCapCard(),
            const SizedBox(height: 24),
            _buildTierOverride(),
            const SizedBox(height: 24),
            const Text(
              'Stand at the door, then tap Start',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                icon: Icon(_icon(_active)),
                label: Text(
                  'Start ${DeviceCapabilityChecker.tierDescription(_active)}',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _color(_active),
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 16),
                ),
                onPressed: _detecting ? null : () => _start(context),
              ),
            ),
            const Spacer(),
            Text(
              'Auto-detects device capabilities.\nOverride buttons above for testing.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapCard() {
    final detected = _detected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _detecting || detected == null
            ? const Row(
                children: [
                  CircularProgressIndicator(strokeWidth: 2),
                  SizedBox(width: 16),
                  Text('Detecting...'),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_icon(detected), color: _color(detected)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          DeviceCapabilityChecker.tierDescription(detected),
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
                    _explain(detected),
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildTierOverride() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Test different modes:',
        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
      ),
      const SizedBox(height: 8),
      Row(
        children: NavigationTier.values.map((t) {
          final isA = _active == t, isD = t == _detected;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: isA ? _color(t).withOpacity(0.1) : null,
                  side: BorderSide(
                    color: isA ? _color(t) : Colors.grey.shade300,
                    width: isA ? 2 : 1,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: () {
                  log('Tier override: $t', name: 'MAIN');
                  setState(() => _override = t == _detected ? null : t);
                },
                child: Column(
                  children: [
                    Icon(_icon(t), size: 20, color: _color(t)),
                    const SizedBox(height: 4),
                    Text(
                      t == NavigationTier.fullAR
                          ? 'Full AR'
                          : t == NavigationTier.sensorAR
                          ? 'Sensor'
                          : '2D Map',
                      style: TextStyle(fontSize: 11, color: _color(t)),
                    ),
                    if (isD)
                      Text(
                        '(detected)',
                        style: TextStyle(fontSize: 9, color: Colors.grey[500]),
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

  void _start(BuildContext ctx) {
    log('Starting navigation with tier: $_active', name: 'MAIN');
    Widget screen;
    switch (_active) {
      case NavigationTier.fullAR:
        log('Launching Tier 1: Full AR', name: 'MAIN');
        screen = ARNavigationScreen(mallJson: _mallData, startNodeId: 'door');
        break;
      case NavigationTier.sensorAR:
        log('Launching Tier 2: Sensor AR + MindAR', name: 'MAIN');
        screen = SensorARScreen(
          mallJson: _mallData,
          startNodeId: 'door',
          initialFacingRadians: 0.0,
          mindFileUrl: 'https://cdn.jsdelivr.net/gh/user/repo/targets.mind',
          imageMarkers: _imageMarkers,
        );
        break;
      case NavigationTier.map2D:
        log('Launching Tier 3: 2D Map', name: 'MAIN');
        screen = Map2DScreen(mallJson: _mallData, startNodeId: 'door');
        break;
    }
    Navigator.push(ctx, MaterialPageRoute(builder: (_) => screen));
  }

  IconData _icon(NavigationTier t) {
    switch (t) {
      case NavigationTier.fullAR:
        return Icons.view_in_ar;
      case NavigationTier.sensorAR:
        return Icons.sensors;
      case NavigationTier.map2D:
        return Icons.map;
    }
  }

  Color _color(NavigationTier t) {
    switch (t) {
      case NavigationTier.fullAR:
        return Colors.blue;
      case NavigationTier.sensorAR:
        return Colors.orange;
      case NavigationTier.map2D:
        return Colors.green;
    }
  }

  String _explain(NavigationTier t) {
    switch (t) {
      case NavigationTier.fullAR:
        return 'ARCore supported! Full 3D AR avatar navigation.';
      case NavigationTier.sensorAR:
        return 'Compass + sensors available. Camera with direction arrow overlay.';
      case NavigationTier.map2D:
        return 'Basic device. 2D map with turn-by-turn directions.';
    }
  }

  // ── DATA ──

  static final List<Map<String, dynamic>> _imageMarkers = [
    {
      "targetIndex": 0,
      "name": "Door Poster",
      "x": 0,
      "y": 0,
      "z": 0,
      "facingRadians": 0.0,
      "nearestNodeId": "door",
    },
    {
      "targetIndex": 1,
      "name": "Desk Sign",
      "x": 4,
      "y": 0,
      "z": 0,
      "facingRadians": 3.1416,
      "nearestNodeId": "desk",
    },
    {
      "targetIndex": 2,
      "name": "Bed Poster",
      "x": 2,
      "y": 0,
      "z": 3,
      "facingRadians": 4.7124,
      "nearestNodeId": "bed",
    },
  ];

  static final Map<String, dynamic> _mallData =
      // {
      //   "nodes": [
      //     {"id": "n0", "x": 0, "y": 0, "z": -0.13, "label": "corner"},
      //     {"id": "n1", "x": 9.38, "y": 0, "z": -0.88, "label": "hook"},
      //     {"id": "n2", "x": 22.5, "y": 0, "z": 0, "label": "end-right"},
      //     {"id": "n3", "x": 0, "y": 0, "z": 9.38, "label": "mid-left"},
      //     {"id": "n4", "x": 0, "y": 0, "z": 18.13, "label": "bottom-left"},
      //     {"id": "n5", "x": 21.25, "y": 0, "z": 29.38, "label": "oval (detached)"},
      //   ],
      //   "edges": [
      //     {"from": "n0", "to": "n1"},
      //     {"from": "n1", "to": "n2"},
      //     {"from": "n0", "to": "n3"},
      //     {"from": "n3", "to": "n4"},
      //     {"from": "n2", "to": "n5"},
      //   ],
      // };
      //  {
      //   "nodes": [
      //     {
      //       "id": "door",
      //       "x": 0,
      //       "y": 0,
      //       "z":  -0.13,
      //       "shopName": null
      //     },
      //     {
      //       "id": "middle",
      //       "x": 9.38,
      //       "y": 0,
      //       "z": -0.88,
      //       "shopName": null
      //     },
      //     {
      //       "id": "room3",
      //       "x":  22.5,
      //       "y": 0,
      //       "z": 0,
      //       "shopName": "Room3"
      //     },
      //     {
      //       "id": "end",
      //       "x": 0,
      //       "y": 0,
      //       "z": 9.38,
      //       "shopName": "End"
      //     },
      //     {
      //       "id": "kitchen",
      //       "x": 0,
      //       "y": 0,
      //       "z": 18.13,
      //       "shopName": "Kitchen"
      //     },
      //     {
      //       "id": "bathroom",
      //       "x":21.25,
      //       "y": 0,
      //       "z":29.38,
      //       "shopName": "Bathroom"
      //     },
      //     {
      //       "id": "n6",
      //       "x": -0.64,
      //       "y": 0,
      //       "z": 2.01,
      //       "shopName": null
      //     }
      //   ],
      //   "edges": [
      //     {
      //       "from": "door",
      //       "to": "middle"
      //     },
      //     {
      //       "from": "door",
      //       "to": "room3"
      //     },
      //     {
      //       "from": "middle",
      //       "to": "room3"
      //     },
      //     {
      //       "from": "middle",
      //       "to": "end"
      //     },
      //     {
      //       "from": "room3",
      //       "to": "bathroom"
      //     },
      //     {
      //       "from": "room3",
      //       "to": "end"
      //     },
      //     {
      //       "from": "end",
      //       "to": "bathroom"
      //     },
      //     {
      //       "from": "bathroom",
      //       "to": "kitchen"
      //     }
      //   ]
      // };
      {
        "nodes": [
          {"id": "door", "x": 0, "y": 0, "z": 0, "shopName": null},
          {"id": "middle", "x": -4.56, "y": 0, "z": -4.07, "shopName": null},
          {"id": "room3", "x": 0, "y": 0, "z": 2, "shopName": "Room3"},
          {"id": "end", "x": 0, "y": 0, "z": 5, "shopName": "End"},
          {"id": "kitchen", "x": 2, "y": 0, "z": 5, "shopName": "Kitchen"},
          {"id": "bathroom", "x": 3, "y": 0, "z": 5, "shopName": "Bathroom"},
          {"id": "n6", "x": -5.1, "y": 0, "z": -2.53, "shopName": null},
          {"id": "n7", "x": 2.79, "y": 0, "z": -4.89, "shopName": null},
          {"id": "n8", "x": 0.61, "y": 0, "z": -3.17, "shopName": null},
        ],
        "edges": [
          {"from": "door", "to": "room3"},
          {"from": "end", "to": "bathroom"},
          {"from": "room3", "to": "end"},
          {"from": "bathroom", "to": "kitchen"},
        ],
      };
}
