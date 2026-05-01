import 'dart:async';
import 'dart:developer';
import 'dart:isolate';
import 'dart:typed_data';

import 'ar_navigation_system.dart';
import 'camera_intrinsics.dart';
import 'feature_format.dart';
import 'localization_service.dart';
import 'mall_data.dart';

// ═══════════════════════════════════════════════════════════════
// IsolateLocalizer — boots one long-lived isolate that owns a
// `LocalizationService` (and therefore the ORB + BFMatcher native
// objects). Per the plan (Phase 2.4): recreating those per scan costs
// 50–150ms; reuse halves cold-to-warm latency.
//
// Requests are correlated by integer `requestId` so multiple in-flight
// scans don't collide. JPEG bytes ride a `TransferableTypedData` so
// they cross the isolate boundary zero-copy.
// ═══════════════════════════════════════════════════════════════

class _LocalizeRequest {
  final int requestId;
  final TransferableTypedData jpeg;
  // Target shop features serialized to plain types (Mat/FFI handles
  // can't cross isolates).
  final String targetShopId;
  final double signWidthM;
  final double signHeightM;
  final List<double> keypointFlat; // K * 5 (xNorm, yNorm, response, size, angle)
  final TransferableTypedData descriptors;
  // Shop world data.
  final double doorstepX;
  final double doorstepY;
  final double doorstepZ;
  final double facingAngle;
  final double heightAboveDoorM;
  // Camera intrinsics.
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final int width;
  final int height;

  _LocalizeRequest({
    required this.requestId,
    required this.jpeg,
    required this.targetShopId,
    required this.signWidthM,
    required this.signHeightM,
    required this.keypointFlat,
    required this.descriptors,
    required this.doorstepX,
    required this.doorstepY,
    required this.doorstepZ,
    required this.facingAngle,
    required this.heightAboveDoorM,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });
}

class _LocalizeResponse {
  final int requestId;
  final double? signX, signY, signZ;
  final double? mallX, mallY, mallZ;
  final double? headingDeg;
  final double confidence;
  final int inlierCount;
  final int goodMatchCount;
  // Encoded as enum index; client maps back to FailReason.
  final int? failReasonIndex;

  _LocalizeResponse({
    required this.requestId,
    this.signX,
    this.signY,
    this.signZ,
    this.mallX,
    this.mallY,
    this.mallZ,
    this.headingDeg,
    required this.confidence,
    required this.inlierCount,
    required this.goodMatchCount,
    this.failReasonIndex,
  });

  factory _LocalizeResponse.fromResult(int id, LocalizationResult r) {
    return _LocalizeResponse(
      requestId: id,
      signX: r.signFramePos?.x,
      signY: r.signFramePos?.y,
      signZ: r.signFramePos?.z,
      mallX: r.mallPosition?.x,
      mallY: r.mallPosition?.y,
      mallZ: r.mallPosition?.z,
      headingDeg: r.mallHeadingDeg,
      confidence: r.confidence,
      inlierCount: r.inlierCount,
      goodMatchCount: r.goodMatchCount,
      failReasonIndex: r.failReason?.index,
    );
  }

  LocalizationResult toResult() {
    final fail = failReasonIndex == null
        ? null
        : FailReason.values[failReasonIndex!];
    return LocalizationResult(
      signFramePos: signX == null ? null : Vector3(signX!, signY!, signZ!),
      mallPosition: mallX == null ? null : Vector3(mallX!, mallY!, mallZ!),
      mallHeadingDeg: headingDeg,
      confidence: confidence,
      inlierCount: inlierCount,
      goodMatchCount: goodMatchCount,
      failReason: fail,
    );
  }
}

class IsolateLocalizer {
  Isolate? _isolate;
  SendPort? _toIsolate;
  late final ReceivePort _fromIsolate;
  final Map<int, Completer<LocalizationResult>> _pending = {};
  int _nextRequestId = 0;
  Future<void>? _spawnFuture;

  /// Idempotent: starts the isolate on first call, returns the existing
  /// instance afterwards.
  Future<void> spawn() {
    return _spawnFuture ??= _spawnImpl();
  }

  Future<void> _spawnImpl() async {
    _fromIsolate = ReceivePort('IsolateLocalizer.from');
    final ready = Completer<SendPort>();
    _fromIsolate.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is _LocalizeResponse) {
        final c = _pending.remove(msg.requestId);
        if (c == null) {
          log('Stray response for requestId=${msg.requestId}', name: 'ISO');
          return;
        }
        c.complete(msg.toResult());
        return;
      }
      log('Unexpected message: $msg', name: 'ISO');
    });
    _isolate = await Isolate.spawn<SendPort>(
      _isolateEntry,
      _fromIsolate.sendPort,
      debugName: 'mall_localizer',
      errorsAreFatal: true,
    );
    _toIsolate = await ready.future;
    log('Isolate ready', name: 'ISO');
  }

  Future<LocalizationResult> localize({
    required Uint8List jpegBytes,
    required ShopFeatures target,
    required Shop shopData,
    required CameraIntrinsics intrinsics,
  }) async {
    await spawn();
    final id = _nextRequestId++;
    final c = Completer<LocalizationResult>();
    _pending[id] = c;

    final keypointFlat = <double>[];
    for (final kp in target.keypoints) {
      keypointFlat.addAll([kp.xNorm, kp.yNorm, kp.response, kp.size, kp.angle]);
    }

    final req = _LocalizeRequest(
      requestId: id,
      jpeg: TransferableTypedData.fromList([jpegBytes]),
      targetShopId: target.shopId,
      signWidthM: target.signWidthM,
      signHeightM: target.signHeightM,
      keypointFlat: keypointFlat,
      descriptors: TransferableTypedData.fromList([target.descriptors]),
      doorstepX: shopData.doorstep.x,
      doorstepY: shopData.doorstep.y,
      doorstepZ: shopData.doorstep.z,
      facingAngle: shopData.facingAngle,
      heightAboveDoorM: shopData.sign.heightAboveDoorMeters,
      fx: intrinsics.fx,
      fy: intrinsics.fy,
      cx: intrinsics.cx,
      cy: intrinsics.cy,
      width: intrinsics.width,
      height: intrinsics.height,
    );
    _toIsolate!.send(req);
    return c.future;
  }

  Future<void> dispose() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toIsolate = null;
    _fromIsolate.close();
    _pending.clear();
  }

  // ── Isolate entry ─────────────────────────────────────────────

  static void _isolateEntry(SendPort toMain) {
    final fromMain = ReceivePort('IsolateLocalizer.toIsolate');
    toMain.send(fromMain.sendPort);

    final svc = LocalizationService();
    svc.warmup();

    fromMain.listen((msg) {
      if (msg is! _LocalizeRequest) {
        log('Isolate ignoring unknown msg: $msg', name: 'ISO');
        return;
      }
      try {
        final result = _runOne(svc, msg);
        toMain.send(_LocalizeResponse.fromResult(msg.requestId, result));
      } catch (e, st) {
        log('Isolate error on req ${msg.requestId}: $e\n$st', name: 'ISO');
        toMain.send(_LocalizeResponse.fromResult(
          msg.requestId,
          LocalizationResult.failure(FailReason.solvePnpFailed),
        ));
      }
    });
  }

  static LocalizationResult _runOne(
      LocalizationService svc, _LocalizeRequest req) {
    final jpegBytes = req.jpeg.materialize().asUint8List();
    final descBytes = req.descriptors.materialize().asUint8List();

    // Reconstruct ShopFeatures from primitives.
    final n = req.keypointFlat.length ~/ 5;
    final kps = <KeyPointMeta>[];
    for (int i = 0; i < n; i++) {
      final base = i * 5;
      kps.add(KeyPointMeta(
        xNorm: req.keypointFlat[base],
        yNorm: req.keypointFlat[base + 1],
        response: req.keypointFlat[base + 2],
        size: req.keypointFlat[base + 3],
        angle: req.keypointFlat[base + 4],
      ));
    }
    // descBytes is a view backed by transferable memory; copy so the
    // service can keep the reference past this scope.
    final target = ShopFeatures(
      shopId: req.targetShopId,
      signWidthM: req.signWidthM,
      signHeightM: req.signHeightM,
      keypoints: kps,
      descriptors: Uint8List.fromList(descBytes),
    );

    // Reconstruct Shop with just the fields the service needs.
    final shop = Shop(
      id: req.targetShopId,
      name: req.targetShopId,
      doorstep: Vector3(req.doorstepX, req.doorstepY, req.doorstepZ),
      facingAngle: req.facingAngle,
      sign: SignDims(
        widthMeters: req.signWidthM,
        heightMeters: req.signHeightM,
        heightAboveDoorMeters: req.heightAboveDoorM,
      ),
    );

    final intrinsics = CameraIntrinsics(
      fx: req.fx,
      fy: req.fy,
      cx: req.cx,
      cy: req.cy,
      width: req.width,
      height: req.height,
    );

    final frame = svc.extractFeatures(jpegBytes);
    if (frame == null) {
      return LocalizationResult.failure(FailReason.decodeFailed);
    }
    try {
      return svc.matchAndLocalize(
        frame: frame,
        target: target,
        shopData: shop,
        intrinsics: intrinsics,
      );
    } finally {
      frame.dispose();
    }
  }
}
