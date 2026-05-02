import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'ar_navigation_system.dart';
import 'feature_format.dart';

// ═══════════════════════════════════════════════════════════════
// Canonical mall data schema (matches sign_surveyor's shops.json).
// ═══════════════════════════════════════════════════════════════

class CoordinateSystem {
  final String units;
  final String angleConvention;
  final String angleRange;
  const CoordinateSystem({
    required this.units,
    required this.angleConvention,
    required this.angleRange,
  });
  factory CoordinateSystem.fromJson(Map<String, dynamic> j) => CoordinateSystem(
        units: j['units'] as String,
        angleConvention: j['angleConvention'] as String,
        angleRange: j['angleRange'] as String,
      );
}

class MallMeta {
  final String id;
  final String name;
  final CoordinateSystem coordinateSystem;
  const MallMeta({
    required this.id,
    required this.name,
    required this.coordinateSystem,
  });
  factory MallMeta.fromJson(Map<String, dynamic> j) => MallMeta(
        id: j['id'] as String,
        name: j['name'] as String,
        coordinateSystem:
            CoordinateSystem.fromJson(j['coordinateSystem'] as Map<String, dynamic>),
      );
}

class SignDims {
  final double widthMeters;
  final double heightMeters;
  final double heightAboveDoorMeters;
  const SignDims({
    required this.widthMeters,
    required this.heightMeters,
    required this.heightAboveDoorMeters,
  });
  factory SignDims.fromJson(Map<String, dynamic> j) => SignDims(
        widthMeters: (j['widthMeters'] as num).toDouble(),
        heightMeters: (j['heightMeters'] as num).toDouble(),
        heightAboveDoorMeters: (j['heightAboveDoorMeters'] as num).toDouble(),
      );
}

class Shop {
  final String id;
  final String name;
  final Vector3 doorstep;
  final double facingAngle;
  final SignDims sign;
  final String? featureFile;
  final int? featureCount;
  const Shop({
    required this.id,
    required this.name,
    required this.doorstep,
    required this.facingAngle,
    required this.sign,
    this.featureFile,
    this.featureCount,
  });
  factory Shop.fromJson(Map<String, dynamic> j) => Shop(
        id: j['id'] as String,
        name: j['name'] as String,
        doorstep: Vector3.fromJson(j['doorstep'] as Map<String, dynamic>),
        facingAngle: (j['facingAngle'] as num).toDouble(),
        sign: SignDims.fromJson(j['sign'] as Map<String, dynamic>),
        featureFile: j['featureFile'] as String?,
        featureCount: (j['featureCount'] as num?)?.toInt(),
      );
}

class MallData {
  final int version;
  final MallMeta mall;
  final Map<String, Shop> shops;
  final NavGraph navigationGraph;

  // Lazy-loaded SSF1 features per shop. Cleared on hot reload via reload().
  final Map<String, ShopFeatures> _featuresCache = {};

  MallData._({
    required this.version,
    required this.mall,
    required this.shops,
    required this.navigationGraph,
  });

  factory MallData.fromJson(Map<String, dynamic> j) {
    final mall = MallMeta.fromJson(j['mall'] as Map<String, dynamic>);

    // Hard fail on convention mismatch — Phase 0 of the plan makes this
    // the load-time invariant that other modules can rely on.
    if (mall.coordinateSystem.units != 'meters') {
      throw StateError(
          'Unsupported units "${mall.coordinateSystem.units}". Expected "meters".');
    }
    if (mall.coordinateSystem.angleConvention != 'ccw_from_positive_x_degrees') {
      throw StateError(
          'Unsupported angleConvention "${mall.coordinateSystem.angleConvention}". '
          'Expected "ccw_from_positive_x_degrees".');
    }

    final shops = <String, Shop>{};
    for (final s in j['shops'] as List) {
      final shop = Shop.fromJson(s as Map<String, dynamic>);
      shops[shop.id] = shop;
    }

    // Map-only destinations: graph nodes whose shopId has no matching real
    // shop (e.g. `n_window` → "window"). Synthesize a featureFile-less Shop
    // so they show up in the destination picker but stay out of the
    // scannable-starting-shop picker (which filters by featureFile != null).
    final rawNav = j['navigationGraph'] as Map<String, dynamic>;
    for (final n in rawNav['nodes'] as List) {
      final m = n as Map;
      final shopId = m['shopId'] as String?;
      if (shopId == null || shops.containsKey(shopId)) continue;
      shops[shopId] = Shop(
        id: shopId,
        name: shopId,
        doorstep: Vector3(
          (m['x'] as num).toDouble(),
          (m['y'] as num).toDouble(),
          (m['z'] as num).toDouble(),
        ),
        facingAngle: 0,
        sign: const SignDims(
          widthMeters: 0,
          heightMeters: 0,
          heightAboveDoorMeters: 0,
        ),
      );
    }

    // Bridge shopId → shopName for the existing NavGraph.fromJson, which
    // reads shopName off each node. shopId is the new schema; shopName is
    // what the legacy NavNode/MapPainter consume.
    final navJson = <String, dynamic>{
      'nodes': (rawNav['nodes'] as List).map((n) {
        final m = Map<String, dynamic>.from(n as Map);
        final shopId = m['shopId'] as String?;
        m['shopName'] = shopId != null ? shops[shopId]?.name : null;
        return m;
      }).toList(),
      'edges': rawNav['edges'],
    };

    final graph = NavGraph.fromJson(navJson);

    return MallData._(
      version: (j['version'] as num).toInt(),
      mall: mall,
      shops: shops,
      navigationGraph: graph,
    );
  }

  // ── Asset loaders ──────────────────────────────────────────────

  static const String kShopsAsset = 'assets/mall/shops.json';

  static Future<MallData> loadFromAssets() async {
    log('Loading $kShopsAsset...', name: 'MALL');
    final raw = await rootBundle.loadString(kShopsAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final data = MallData.fromJson(json);
    log('Loaded mall "${data.mall.name}" (v${data.version}) with '
        '${data.shops.length} shops, ${data.navigationGraph.nodes.length} nodes',
        name: 'MALL');
    return data;
  }

  // Lazy-loads a shop's SSF1 features. Cached after first load.
  // Throws if the shop has no featureFile or the file is missing.
  Future<ShopFeatures> loadFeaturesForShop(String shopId) async {
    final cached = _featuresCache[shopId];
    if (cached != null) return cached;

    final shop = shops[shopId];
    if (shop == null) throw StateError('Unknown shop "$shopId"');
    final featureFile = shop.featureFile;
    if (featureFile == null) {
      throw StateError('Shop "$shopId" has no featureFile');
    }

    // featureFile in shops.json is "output/<id>.bin" (the surveyor's path).
    // Sync script copies the file to assets/mall/features/<id>.bin and we
    // resolve to the asset basename here so the JSON stays as-shipped.
    final basename = featureFile.split('/').last;
    final assetPath = 'assets/mall/features/$basename';
    log('Loading features for "$shopId" from $assetPath', name: 'MALL');

    final bytes = await rootBundle.load(assetPath);
    final features = await loadSsf1(bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    ));

    if (features.shopId != shopId) {
      throw StateError('Feature file shopId mismatch: '
          'expected "$shopId", file has "${features.shopId}"');
    }
    if (shop.featureCount != null &&
        features.keypoints.length != shop.featureCount) {
      log('WARNING: featureCount mismatch for "$shopId": '
          'expected ${shop.featureCount}, got ${features.keypoints.length}',
          name: 'MALL');
    }

    _featuresCache[shopId] = features;
    return features;
  }

  // For tests — accept raw bytes instead of an asset path.
  Future<ShopFeatures> loadFeaturesFromBytes(String shopId, Uint8List bytes) async {
    final features = await loadSsf1(bytes);
    _featuresCache[shopId] = features;
    return features;
  }

  void clearFeatureCache() => _featuresCache.clear();
}
