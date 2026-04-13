import 'package:flutter/material.dart';

enum StoreType { store, elevator, stairs }

class Store {
  final String id;
  final String name;
  final Offset position; // x, y from JSON
  final int floor;       // z from JSON
  final StoreType type;

  const Store({
    required this.id,
    required this.name,
    required this.position,
    required this.floor,
    required this.type,
  });

  factory Store.fromJson(Map<String, dynamic> json) {
    final typeStr = (json['type'] as String? ?? 'store').toLowerCase();
    StoreType storeType;
    switch (typeStr) {
      case 'elevator':
        storeType = StoreType.elevator;
        break;
      case 'stairs':
        storeType = StoreType.stairs;
        break;
      default:
        storeType = StoreType.store;
    }

    return Store(
      id: json['id'].toString(),
      name: json['name'] as String,
      position: Offset(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      ),
      floor: (json['z'] as num).toInt(),
      type: storeType,
    );
  }
}

class MapData {
  final List<Store> nodes;
  final List<Map<String, String>> edges;

  const MapData({required this.nodes, required this.edges});

  factory MapData.fromJson(Map<String, dynamic> json) {
    final nodesList = (json['nodes'] as List<dynamic>)
        .map((e) => Store.fromJson(e as Map<String, dynamic>))
        .toList();

    final edgesList = (json['edges'] as List<dynamic>? ?? [])
        .map((e) {
      final m = e as Map<String, dynamic>;
      return {
        'from': m['from'].toString(),
        'to': m['to'].toString(),
      };
    })
        .toList();

    return MapData(nodes: nodesList, edges: edgesList);
  }
}
