// ══════════════════════════════════════════════════════════════════════════════
// main.dart
//
// Entry point for the AR Mall Navigation app.
// Uses initial position mode — no QR codes needed.
//
// For home testing:
//   1. Measure your room and update _mallData below.
//   2. Stand at the "door" node when you open the app.
//   3. The AR origin becomes "door" automatically.
//   4. Pick a destination and walk!
// ══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'ar_navigation_screen.dart';

void main() {
  runApp(const MallNavigationApp());
}

class MallNavigationApp extends StatelessWidget {
  const MallNavigationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Mall Navigator',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Mall Navigator')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Stand at the door, then tap Start',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.navigation),
              label: const Text('Start Navigation'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ARNavigationScreen(
                      mallJson: _mallData,
                      // Tell the system: "I am currently at the door node."
                      // AR origin (0,0,0) will be mapped to this node's position.
                      startNodeId: 'door',
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  // ROOM MAP DATA (for home testing)
  //
  // Measure your room with a tape measure and fill in the positions.
  // Stand at the "door" node when you press Start.
  //
  //   door (0,0,0) ──── middle (2,0,0) ──── desk (4,0,0)
  //       |                   |                   |
  //   closet (0,0,3) ──── bed (2,0,3) ──── window (4,0,3)
  //
  // ════════════════════════════════════════════════════════════════

  static final Map<String, dynamic> _mallData = {
    "nodes": [
      {"id": "door",       "x": 0,  "y": 0, "z": 0,  "shopName": null},
      {"id": "middle",     "x": 2,  "y": 0, "z": 0,  "shopName": null},
      {"id": "desk",       "x": 4,  "y": 0, "z": 0,  "shopName": "Desk"},
      {"id": "bed",        "x": 2,  "y": 0, "z": 3,  "shopName": "Bed"},
      {"id": "window",     "x": 4,  "y": 0, "z": 3,  "shopName": "Window"},
      {"id": "closet",     "x": 0,  "y": 0, "z": 3,  "shopName": "Closet"},
    ],
    "edges": [
      {"from": "door",   "to": "middle"},
      {"from": "middle", "to": "desk"},
      {"from": "middle", "to": "bed"},
      {"from": "bed",    "to": "window"},
      {"from": "bed",    "to": "closet"},
      {"from": "closet", "to": "door"},
    ],
  };
}
