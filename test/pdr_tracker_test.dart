import 'package:flutter_test/flutter_test.dart';
import 'package:test_sensors/ar_navigation_system.dart';
import 'package:test_sensors/pdr_tracker.dart';

void main() {
  // ── start / stop ─────────────────────────────────────────────────
  group('PDRTracker start/stop', () {
    test('start and stop do not throw on non-mobile platform', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      expect(() { pdr.start(); pdr.stop(); }, returnsNormally);
    });

    test('initial state is correct', () {
      final pdr = PDRTracker(startPosition: const Vector3(1, 2, 3));
      expect(pdr.currentPosition.x, closeTo(1.0, 1e-9));
      expect(pdr.currentPosition.y, closeTo(2.0, 1e-9));
      expect(pdr.currentPosition.z, closeTo(3.0, 1e-9));
      expect(pdr.totalSteps, 0);
      expect(pdr.stepsSinceLastFix, 0);
      expect(pdr.lastFixAt, isNull);
      expect(pdr.isWalkingDetected, isFalse);
    });
  });

  // ── correctPosition ───────────────────────────────────────────────
  group('correctPosition', () {
    test('updates currentPosition to the given value', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      pdr.correctPosition(const Vector3(5.0, 1.0, 3.0));
      expect(pdr.currentPosition.x, closeTo(5.0, 1e-9));
      expect(pdr.currentPosition.y, closeTo(1.0, 1e-9));
      expect(pdr.currentPosition.z, closeTo(3.0, 1e-9));
    });

    test('resets stepsSinceLastFix to zero', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      // Simulate steps having accumulated (we manipulate via a second fix).
      pdr.correctPosition(const Vector3(1, 0, 0));
      expect(pdr.stepsSinceLastFix, 0);
    });

    test('sets lastFixAt to a recent timestamp', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      final before = DateTime.now();
      pdr.correctPosition(const Vector3(1, 0, 0));
      final after = DateTime.now();
      expect(pdr.lastFixAt, isNotNull);
      expect(pdr.lastFixAt!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(pdr.lastFixAt!.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('fires onPositionUpdate callback', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      Vector3? fired;
      pdr.onPositionUpdate = (p) => fired = p;
      pdr.correctPosition(const Vector3(7, 0, 0));
      expect(fired?.x, closeTo(7.0, 1e-9));
    });
  });

  // ── correctPositionAndHeading ──────────────────────────────────────
  group('correctPositionAndHeading', () {
    test('always corrects position even when heading not yet initialized', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      pdr.correctPositionAndHeading(const Vector3(4, 0, 2), 90.0);
      expect(pdr.currentPosition.x, closeTo(4.0, 1e-9));
      expect(pdr.currentPosition.z, closeTo(2.0, 1e-9));
    });

    test('skips heading update when heading not initialized', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      pdr.correctPositionAndHeading(const Vector3(1, 0, 0), 45.0);
      // _initialHeadingSet is false, so _initialHeading stays at 0.0.
      expect(pdr.initialHeading, closeTo(0.0, 1e-9));
    });

    test('adjusts initialHeading when compass is already latched', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      // Seed compass at 180° so _initialHeadingSet = true, _heading = 180.
      pdr.setInitialHeadingForTest(180.0);

      pdr.correctPositionAndHeading(const Vector3(0, 0, 0), 90.0);

      // Expected: _initialHeading = _heading − (mallHeading − initialMapFacingDeg)
      //         = 180 − (90 − 0) = 90
      expect(pdr.initialHeading, closeTo(90.0, 1e-9));
    });

    test('heading getter unchanged after correction (reflects current compass)', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      pdr.setInitialHeadingForTest(270.0);
      pdr.correctPositionAndHeading(const Vector3(0, 0, 0), 0.0);
      // heading always reflects the smoothed compass reading, not the mall heading.
      expect(pdr.heading, closeTo(270.0, 1e-9));
    });
  });

  // ── snapToNodes ────────────────────────────────────────────────────
  group('snapToNodes', () {
    NavNode makeNode(String id, double x, double z) =>
        NavNode(id: id, position: Vector3(x, 0, z));

    test('snaps to nearest candidate within maxDist', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      final candidates = [makeNode('A', 2, 0), makeNode('B', 5, 0)];
      pdr.snapToNodes(candidates, maxDist: 3.0);
      expect(pdr.currentPosition.x, closeTo(2.0, 1e-9));
    });

    test('does not snap when all candidates are beyond maxDist', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      final candidates = [makeNode('A', 5, 0), makeNode('B', 8, 0)];
      pdr.snapToNodes(candidates, maxDist: 3.0);
      expect(pdr.currentPosition.x, closeTo(0.0, 1e-9));
    });

    test('picks nearest among multiple within maxDist', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      final candidates = [makeNode('A', 2, 0), makeNode('B', 1, 0)];
      pdr.snapToNodes(candidates, maxDist: 5.0);
      expect(pdr.currentPosition.x, closeTo(1.0, 1e-9));
    });

    test('empty candidate list is a no-op', () {
      final pdr = PDRTracker(startPosition: const Vector3(3, 0, 0));
      pdr.snapToNodes([]);
      expect(pdr.currentPosition.x, closeTo(3.0, 1e-9));
    });
  });

  // ── resetWalkingState ──────────────────────────────────────────────
  group('resetWalkingState', () {
    test('resets isWalkingDetected to false', () {
      final pdr = PDRTracker(startPosition: const Vector3(0, 0, 0));
      pdr.resetWalkingState();
      expect(pdr.isWalkingDetected, isFalse);
    });
  });
}
