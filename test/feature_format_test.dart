import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_sensors/feature_format.dart';

void main() {
  group('SSF1 binary reader', () {
    test('parses surveyor-produced zara.bin', () async {
      // The sync script copies sign_surveyor's output here.
      final file = File('assets/mall/features/zara.bin');
      expect(file.existsSync(), isTrue,
          reason: 'Run scripts/sync_mall_assets.sh first to populate '
              'assets/mall/features/.');

      final bytes = await file.readAsBytes();
      final features = await loadSsf1(bytes);

      expect(features.shopId, 'zara');
      expect(features.signWidthM, closeTo(0.7, 0.001));
      expect(features.signHeightM, closeTo(0.5, 0.001));
      // Surveyor keeps top-80 keypoints by ORB response (KEEP_TOP_K=80).
      expect(features.keypoints.length, 80);
      expect(features.descriptors.length,
          features.keypoints.length * ShopFeatures.descriptorBytes);
    });

    test('rejects bytes without SSF1 magic', () async {
      await expectLater(
        loadSsf1(Uint8List.fromList(List.filled(64, 0))),
        throwsA(isA<Ssf1FormatException>()),
      );
    });
  });
}
