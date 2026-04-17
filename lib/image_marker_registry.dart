import 'dart:developer';
import 'ar_navigation_system.dart';

class ImageMarker {
  final int targetIndex;
  final String name;
  final Vector3 position;
  final double facingRadians;
  final String? nearestNodeId;

  const ImageMarker({required this.targetIndex, required this.name, required this.position, required this.facingRadians, this.nearestNodeId});

  factory ImageMarker.fromJson(Map<String, dynamic> j) => ImageMarker(
        targetIndex: j['targetIndex'] as int,
        name: j['name'] as String,
        position: Vector3.fromJson(j),
        facingRadians: (j['facingRadians'] as num).toDouble(),
        nearestNodeId: j['nearestNodeId'] as String?,
      );

  @override
  String toString() => 'ImageMarker(#$targetIndex "$name" pos=$position facing=${facingRadians.toStringAsFixed(2)}rad node=$nearestNodeId)';
}

class ImageMarkerRegistry {
  final Map<int, ImageMarker> _markers = {};

  void register(ImageMarker m) {
    _markers[m.targetIndex] = m;
    log('Registered: $m', name: 'MARKERS');
  }

  ImageMarker? lookup(int idx) {
    final m = _markers[idx];
    log('Lookup index=$idx → ${m ?? "NOT FOUND"}', name: 'MARKERS');
    return m;
  }

  int get count => _markers.length;

  void loadFromJson(List<Map<String, dynamic>> json) {
    for (final e in json) register(ImageMarker.fromJson(e));
    log('Loaded ${json.length} markers total', name: 'MARKERS');
  }

  List<ImageMarker> get all => _markers.values.toList();
}
