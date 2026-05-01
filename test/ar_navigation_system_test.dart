import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:test_sensors/ar_navigation_system.dart';

// ── helpers ─────────────────────────────────────────────────────

NavGraph _linearGraph() => NavGraph.fromJson({
      'nodes': [
        {'id': 'A', 'x': 0.0, 'y': 0.0, 'z': 0.0},
        {'id': 'B', 'x': 1.0, 'y': 0.0, 'z': 0.0},
        {'id': 'C', 'x': 2.0, 'y': 0.0, 'z': 0.0},
      ],
      'edges': [
        {'from': 'A', 'to': 'B', 'weight': 1.0},
        {'from': 'B', 'to': 'C', 'weight': 1.0},
      ],
    });

NavGraph _weightedGraph() => NavGraph.fromJson({
      'nodes': [
        {'id': 'A', 'x': 0.0, 'y': 0.0, 'z': 0.0},
        {'id': 'B', 'x': 1.0, 'y': 0.0, 'z': 0.0},
        {'id': 'C', 'x': 0.0, 'y': 0.0, 'z': 1.0},
        {'id': 'D', 'x': 1.0, 'y': 0.0, 'z': 1.0},
      ],
      'edges': [
        {'from': 'A', 'to': 'B', 'weight': 1.0},  // cost 1*1 = 1
        {'from': 'A', 'to': 'C', 'weight': 10.0}, // cost 1*10 = 10
        {'from': 'B', 'to': 'D', 'weight': 1.0},  // cost 1*1 = 1
        {'from': 'C', 'to': 'D', 'weight': 1.0},  // cost 1*1 = 1
      ],
    });

// ── Vector3 ──────────────────────────────────────────────────────

void main() {
  group('Vector3', () {
    test('distanceTo self is zero', () {
      const v = Vector3(3, 4, 5);
      expect(v.distanceTo(v), closeTo(0.0, 1e-9));
    });

    test('distanceTo known values', () {
      const a = Vector3(0, 0, 0);
      const b = Vector3(3, 4, 0);
      expect(a.distanceTo(b), closeTo(5.0, 1e-9));
    });

    test('operator + and -', () {
      const a = Vector3(1, 2, 3);
      const b = Vector3(4, 5, 6);
      final sum = a + b;
      expect(sum.x, closeTo(5.0, 1e-9));
      expect(sum.y, closeTo(7.0, 1e-9));
      expect(sum.z, closeTo(9.0, 1e-9));
      final diff = b - a;
      expect(diff.x, closeTo(3.0, 1e-9));
      expect(diff.y, closeTo(3.0, 1e-9));
      expect(diff.z, closeTo(3.0, 1e-9));
    });
  });

  // ── NavGraph ─────────────────────────────────────────────────────

  group('NavGraph', () {
    test('findPath returns correct 3-node path', () {
      final g = _linearGraph();
      final path = g.findPath('A', 'C');
      expect(path, isNotNull);
      expect(path!.map((n) => n.id).toList(), ['A', 'B', 'C']);
    });

    test('findPath bidirectional: C to A', () {
      final g = _linearGraph();
      final path = g.findPath('C', 'A');
      expect(path, isNotNull);
      expect(path!.map((n) => n.id).toList(), ['C', 'B', 'A']);
    });

    test('findPath start == goal returns single node', () {
      final g = _linearGraph();
      final path = g.findPath('B', 'B');
      expect(path, isNotNull);
      expect(path!.length, 1);
      expect(path.first.id, 'B');
    });

    test('findPath returns null for unknown node', () {
      final g = _linearGraph();
      expect(g.findPath('A', 'UNKNOWN'), isNull);
      expect(g.findPath('UNKNOWN', 'A'), isNull);
    });

    test('findPath returns null when goal is unreachable', () {
      final g = NavGraph.fromJson({
        'nodes': [
          {'id': 'A', 'x': 0.0, 'y': 0.0, 'z': 0.0},
          {'id': 'B', 'x': 1.0, 'y': 0.0, 'z': 0.0},
          {'id': 'C', 'x': 5.0, 'y': 0.0, 'z': 0.0}, // isolated
        ],
        'edges': [
          {'from': 'A', 'to': 'B'},
        ],
      });
      expect(g.findPath('A', 'C'), isNull);
    });

    test('weighted graph picks cheapest path', () {
      final g = _weightedGraph();
      final path = g.findPath('A', 'D');
      expect(path, isNotNull);
      // Cheap route: A→B→D (cost 2). Expensive: A→C→D (cost 11).
      expect(path!.map((n) => n.id).toList(), ['A', 'B', 'D']);
    });

    test('oneway edge is not traversed in reverse', () {
      final g = NavGraph.fromJson({
        'nodes': [
          {'id': 'A', 'x': 0.0, 'y': 0.0, 'z': 0.0},
          {'id': 'B', 'x': 1.0, 'y': 0.0, 'z': 0.0},
        ],
        'edges': [
          {'from': 'A', 'to': 'B', 'oneway': true},
        ],
      });
      expect(g.findPath('A', 'B'), isNotNull);
      expect(g.findPath('B', 'A'), isNull);
    });

    test('pathDistance sums edge lengths', () {
      final g = _linearGraph();
      final path = g.findPath('A', 'C')!;
      expect(g.pathDistance(path), closeTo(2.0, 1e-9));
    });

    test('pathDistance for single node is zero', () {
      final g = _linearGraph();
      expect(g.pathDistance([g.nodes['A']!]), closeTo(0.0, 1e-9));
    });

    test('findNearestNode returns closest', () {
      final g = NavGraph.fromJson({
        'nodes': [
          {'id': 'near', 'x': 1.0, 'y': 0.0, 'z': 0.0},
          {'id': 'mid', 'x': 5.0, 'y': 0.0, 'z': 0.0},
          {'id': 'far', 'x': 10.0, 'y': 0.0, 'z': 0.0},
        ],
        'edges': [],
      });
      // Query at (3, 0, 0): distances are 2, 2, 7 → near and mid are equal.
      // Query at (4, 0, 0): distances are 3, 1, 6 → mid wins.
      expect(g.findNearestNode(const Vector3(4.0, 0.0, 0.0)), 'mid');
      expect(g.findNearestNode(const Vector3(0.0, 0.0, 0.0)), 'near');
      expect(g.findNearestNode(const Vector3(9.0, 0.0, 0.0)), 'far');
    });
  });

  // ── CoordinateAligner ────────────────────────────────────────────

  group('CoordinateAligner', () {
    test('isAligned is false before alignment', () {
      final a = CoordinateAligner();
      expect(a.isAligned, isFalse);
    });

    test('arToMap and mapToAR return null before alignment', () {
      final a = CoordinateAligner();
      expect(a.arToMap(const Vector3(1, 0, 0)), isNull);
      expect(a.mapToAR(const Vector3(1, 0, 0)), isNull);
    });

    group('zero yaw (no yaw args)', () {
      late CoordinateAligner aligner;

      setUp(() {
        aligner = CoordinateAligner();
        aligner.alignFromQRCode(
          knownMapPosition: const Vector3(1.0, 0.0, 0.0),
          arDetectedPosition: const Vector3(4.0, 0.0, 0.0),
        );
      });

      test('isAligned is true after alignment', () {
        expect(aligner.isAligned, isTrue);
      });

      test('mapToAR of the known map position equals arDetectedPosition', () {
        final ar = aligner.mapToAR(const Vector3(1.0, 0.0, 0.0))!;
        expect(ar.x, closeTo(4.0, 1e-9));
        expect(ar.y, closeTo(0.0, 1e-9));
        expect(ar.z, closeTo(0.0, 1e-9));
      });

      test('arToMap round-trip restores original map position', () {
        const mapPos = Vector3(2.0, 1.0, 3.0);
        final ar = aligner.mapToAR(mapPos)!;
        final back = aligner.arToMap(ar)!;
        expect(back.x, closeTo(mapPos.x, 1e-9));
        expect(back.y, closeTo(mapPos.y, 1e-9));
        expect(back.z, closeTo(mapPos.z, 1e-9));
      });
    });

    group('90° yaw offset', () {
      late CoordinateAligner aligner;

      setUp(() {
        aligner = CoordinateAligner();
        // Camera has yawed 90° more than the map expects.
        aligner.alignFromQRCode(
          knownMapPosition: const Vector3(3.0, 0.0, 0.0),
          arDetectedPosition: const Vector3(0.0, 0.0, 3.0),
          arCameraYaw: math.pi / 2,
          knownMapYaw: 0.0,
        );
      });

      test('mapToAR of known position equals arDetectedPosition', () {
        final ar = aligner.mapToAR(const Vector3(3.0, 0.0, 0.0))!;
        expect(ar.x, closeTo(0.0, 1e-9));
        expect(ar.y, closeTo(0.0, 1e-9));
        expect(ar.z, closeTo(3.0, 1e-9));
      });

      test('arToMap round-trip', () {
        const mapPos = Vector3(1.0, 2.0, 0.0);
        final ar = aligner.mapToAR(mapPos)!;
        final back = aligner.arToMap(ar)!;
        expect(back.x, closeTo(mapPos.x, 1e-9));
        expect(back.y, closeTo(mapPos.y, 1e-9));
        expect(back.z, closeTo(mapPos.z, 1e-9));
      });
    });
  });

  // ── AvatarGuide ──────────────────────────────────────────────────

  group('AvatarGuide', () {
    NavNode node(String id, double x, double z) =>
        NavNode(id: id, position: Vector3(x, 0, z));

    test('initial state is waitingForAlignment', () {
      final g = AvatarGuide();
      expect(g.state, NavigationState.waitingForAlignment);
    });

    test('startNavigation transitions to navigating and fires onAvatarMoved', () {
      final g = AvatarGuide();
      NavNode? moved;
      g.onAvatarMoved = (n) => moved = n;

      final path = [node('A', 0, 0), node('B', 1, 0), node('C', 2, 0)];
      g.startNavigation(path);

      expect(g.state, NavigationState.navigating);
      expect(moved?.id, 'B'); // first target after start node
      expect(g.currentTarget?.id, 'B');
    });

    test('update far from waypoint does not advance', () {
      final g = AvatarGuide(arrivalThreshold: 0.5);
      final path = [node('A', 0, 0), node('B', 10, 0)];
      g.startNavigation(path);

      g.update(const Vector3(0, 0, 0)); // still far from B
      expect(g.state, NavigationState.navigating);
      expect(g.currentTarget?.id, 'B');
    });

    test('update within arrivalThreshold advances waypoint', () {
      final g = AvatarGuide(arrivalThreshold: 0.8);
      NavNode? moved;
      g.onAvatarMoved = (n) => moved = n;

      final path = [node('A', 0, 0), node('B', 1, 0), node('C', 2, 0)];
      g.startNavigation(path);
      moved = null; // reset after startNavigation fired

      // Step close to B.
      g.update(const Vector3(1.0, 0, 0));

      expect(g.state, NavigationState.navigating);
      expect(g.currentTarget?.id, 'C');
      expect(moved?.id, 'C');
    });

    test('reaching final waypoint transitions to arrived', () {
      final g = AvatarGuide(arrivalThreshold: 0.8);
      bool arrived = false;
      g.onArrived = () => arrived = true;

      final path = [node('A', 0, 0), node('B', 1, 0)];
      g.startNavigation(path);

      g.update(const Vector3(1.0, 0, 0)); // within threshold of B
      expect(g.state, NavigationState.arrived);
      expect(arrived, isTrue);
    });

    test('onDistanceUpdate is called on each update while navigating', () {
      final g = AvatarGuide(arrivalThreshold: 0.1);
      double? lastDist;
      g.onDistanceUpdate = (d, _) => lastDist = d;

      final path = [node('A', 0, 0), node('B', 5, 0)];
      g.startNavigation(path);

      g.update(const Vector3(2.0, 0, 0));
      expect(lastDist, closeTo(3.0, 1e-9));
    });

    test('update does nothing when not navigating', () {
      final g = AvatarGuide();
      // state = waitingForAlignment, no path — should not throw
      g.update(const Vector3(0, 0, 0));
      expect(g.state, NavigationState.waitingForAlignment);
    });
  });
}
