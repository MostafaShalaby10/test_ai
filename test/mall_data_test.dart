import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_sensors/mall_data.dart';

void main() {
  // Fixture matches the canonical schema (sign_surveyor's shops.json layout).
  const fixtureJson = '''
  {
    "version": 1,
    "mall": {
      "id": "test_mall",
      "name": "Test Mall",
      "coordinateSystem": {
        "units": "meters",
        "angleConvention": "ccw_from_positive_x_degrees",
        "angleRange": "[0, 360)"
      }
    },
    "shops": [
      {
        "id": "window",
        "name": "Window",
        "doorstep": {"x": 3, "y": 0, "z": 0},
        "facingAngle": 90,
        "sign": {
          "widthMeters": 1.2,
          "heightMeters": 0.4,
          "heightAboveDoorMeters": 2.1
        },
        "featureFile": "output/window.bin",
        "featureCount": 80
      }
    ],
    "navigationGraph": {
      "nodes": [
        {"id": "door", "x": 0, "y": 0, "z": 0, "shopId": null},
        {"id": "n_window", "x": 3, "y": 0, "z": 0, "shopId": "window"}
      ],
      "edges": [
        {"from": "door", "to": "n_window", "weight": 1.0}
      ]
    }
  }
  ''';

  test('MallData.fromJson parses canonical schema', () {
    final data =
        MallData.fromJson(jsonDecode(fixtureJson) as Map<String, dynamic>);
    expect(data.version, 1);
    expect(data.mall.name, 'Test Mall');
    expect(data.shops.length, 1);
    final shop = data.shops['window']!;
    expect(shop.name, 'Window');
    // Vector3 has no operator==, so compare components.
    expect(shop.doorstep.x, 3);
    expect(shop.doorstep.y, 0);
    expect(shop.doorstep.z, 0);
    expect(shop.facingAngle, 90);
    expect(shop.sign.widthMeters, 1.2);
    expect(shop.featureCount, 80);
  });

  test('NavGraph built from JSON supports A* across shop nodes', () {
    final data =
        MallData.fromJson(jsonDecode(fixtureJson) as Map<String, dynamic>);
    final path = data.navigationGraph.findPath('door', 'n_window');
    expect(path, isNotNull);
    expect(path!.length, 2);
    expect(path.first.id, 'door');
    expect(path.last.id, 'n_window');
    // shopId → shopName bridge: the surveyor's "window" shop should be
    // exposed via shopName on the corresponding node.
    expect(path.last.shopName, 'Window');
  });

  test('fromJson rejects mismatched coordinate system', () {
    final bad = jsonDecode(fixtureJson) as Map<String, dynamic>;
    (bad['mall']
            as Map<String, dynamic>)['coordinateSystem']['angleConvention'] =
        'cw_from_north_degrees';
    expect(() => MallData.fromJson(bad), throwsStateError);
  });
}
