import 'dart:convert';
import 'dart:typed_data';

// ═══════════════════════════════════════════════════════════════
// SSF1 — Sign Survey Features v1
// Mirror of sign_surveyor/feature_format.py.
//
// Pure Dart, no opencv_dart dependency, so this file is testable on the
// host VM via `flutter test` without the native OpenCV runtime.
//
// Byte layout (little-endian):
//   0       4       magic = "SSF1"
//   4       4       version (u32) = 1
//   8       4       shop_id_len (u32)
//   12      N       shop_id (UTF-8)
//   12+N    4       sign_width_m (f32)
//   16+N    4       sign_height_m (f32)
//   20+N    4       n_keypoints (u32)
//   24+N    20*K    keypoints: K * (x_norm, y_norm, response, size, angle) f32
//   24+N+20K 32*K   descriptors: K * 32 bytes (ORB-256)
// ═══════════════════════════════════════════════════════════════

class KeyPointMeta {
  final double xNorm;
  final double yNorm;
  final double response;
  final double size;
  final double angle;
  const KeyPointMeta({
    required this.xNorm,
    required this.yNorm,
    required this.response,
    required this.size,
    required this.angle,
  });
}

class ShopFeatures {
  final String shopId;
  final double signWidthM;
  final double signHeightM;
  final List<KeyPointMeta> keypoints;
  final Uint8List descriptors; // K * 32 bytes, row-major

  const ShopFeatures({
    required this.shopId,
    required this.signWidthM,
    required this.signHeightM,
    required this.keypoints,
    required this.descriptors,
  });

  int get descriptorRows => keypoints.length;
  static const int descriptorBytes = 32;
}

class Ssf1FormatException implements Exception {
  final String message;
  Ssf1FormatException(this.message);
  @override
  String toString() => 'Ssf1FormatException: $message';
}

const _magic = [0x53, 0x53, 0x46, 0x31]; // "SSF1"
const _version = 1;
const _kpStride = 20; // 5 floats * 4 bytes
const _descStride = 32;

Future<ShopFeatures> loadSsf1(Uint8List bytes) async {
  if (bytes.length < 24) {
    throw Ssf1FormatException('File too short (${bytes.length} bytes)');
  }
  for (int i = 0; i < 4; i++) {
    if (bytes[i] != _magic[i]) {
      throw Ssf1FormatException('Bad magic — not an SSF1 file');
    }
  }
  final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

  final version = bd.getUint32(4, Endian.little);
  if (version != _version) {
    throw Ssf1FormatException('Unsupported version $version (expected $_version)');
  }

  final idLen = bd.getUint32(8, Endian.little);
  if (12 + idLen + 12 > bytes.length) {
    throw Ssf1FormatException('Truncated header (id_len=$idLen)');
  }
  final shopId = utf8.decode(bytes.sublist(12, 12 + idLen));

  int off = 12 + idLen;
  final signW = bd.getFloat32(off, Endian.little); off += 4;
  final signH = bd.getFloat32(off, Endian.little); off += 4;
  final n = bd.getUint32(off, Endian.little); off += 4;

  final kpStart = off;
  final descStart = kpStart + n * _kpStride;
  final expectedEnd = descStart + n * _descStride;
  if (expectedEnd > bytes.length) {
    throw Ssf1FormatException(
        'File truncated: expected $expectedEnd bytes, got ${bytes.length} '
        '(n=$n keypoints)');
  }

  final keypoints = List<KeyPointMeta>.generate(n, (i) {
    final base = kpStart + i * _kpStride;
    return KeyPointMeta(
      xNorm: bd.getFloat32(base, Endian.little),
      yNorm: bd.getFloat32(base + 4, Endian.little),
      response: bd.getFloat32(base + 8, Endian.little),
      size: bd.getFloat32(base + 12, Endian.little),
      angle: bd.getFloat32(base + 16, Endian.little),
    );
  });

  // Copy the descriptor blob — caller may keep it after `bytes` goes away.
  final descriptors = Uint8List.fromList(
    bytes.sublist(descStart, descStart + n * _descStride),
  );

  return ShopFeatures(
    shopId: shopId,
    signWidthM: signW,
    signHeightM: signH,
    keypoints: keypoints,
    descriptors: descriptors,
  );
}
