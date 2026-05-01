import 'dart:developer';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'ar_navigation_system.dart';
import 'camera_intrinsics.dart';
import 'feature_format.dart';
import 'mall_data.dart';
import 'mall_geometry.dart' as geom;

// ═══════════════════════════════════════════════════════════════
// LocalizationService — wraps every opencv_dart call needed for the
// scan-on-tap visual fix. Per the plan (line 122), if we ever need to
// swap OpenCV bindings (e.g. native platform channels), only this file
// changes.
//
// Pipeline (matching sign_surveyor's offline pipeline so on-device and
// validation harness produce comparable results):
//   1. JPEG → grayscale Mat
//   2. Laplacian variance → blur gate (rejects shaky shots)
//   3. ORB detectAndCompute (nFeatures=500, scaleFactor=1.2, nLevels=8,
//      edgeThreshold=15), keep top 100 by response
//   4. BFMatcher knnMatch (NORM_HAMMING, crossCheck=false), Lowe ratio
//      0.75 → good matches
//   5. findHomography (RANSAC, 3px reproj) on (sign-norm → image-pixel)
//   6. perspectiveTransform on canonical sign corners → image-pixel
//      corners
//   7. solvePnP (SOLVEPNP_IPPE_SQUARE — 4-point planar) with the sign
//      rectangle in meters as object points → camera pose in sign frame
//   8. mall_geometry.signFrameToMallFrame → user position in mall coords
//   9. Heading from rotation matrix forward column
//  10. Sanity gates (height, distance) before returning success
// ═══════════════════════════════════════════════════════════════

const int _solvePnpIppeSquare = 7; // OpenCV's SOLVEPNP_IPPE_SQUARE
const int _orbNFeatures = 500;
const double _orbScaleFactor = 1.2;
const int _orbNLevels = 8;
const int _orbEdgeThreshold = 15;
const int _keepTopK = 100;
const double _loweRatio = 0.75;
const int _minGoodMatches = 15;
const int _minInliers = 10;
const double _ransacReprojThreshold = 3.0;
const double _blurLaplacianThreshold = 80.0;

// Sanity-check bounds for the recovered camera pose.
const double _minDistanceM = 0.5;
const double _maxDistanceM = 30.0;
const double _minHeightM = -1.0; // below floor — clearly bogus
const double _maxHeightM = 3.0;  // above ceiling for a single-storey mall

enum FailReason {
  decodeFailed,
  blurryFrame,
  noKeypoints,
  lowMatches,
  badHomography,
  lowInliers,
  solvePnpFailed,
  sanityCheck,
}

String failReasonHumanMessage(FailReason r) {
  switch (r) {
    case FailReason.decodeFailed:
      return 'Could not decode image';
    case FailReason.blurryFrame:
      return 'Sign too blurry — hold steady and retake';
    case FailReason.noKeypoints:
      return 'No features detected — try better lighting';
    case FailReason.lowMatches:
      return 'Sign not recognized — get closer or face it head-on';
    case FailReason.badHomography:
      return 'Sign geometry unclear — face it more directly';
    case FailReason.lowInliers:
      return 'Too few matching features — get closer';
    case FailReason.solvePnpFailed:
      return 'Pose estimation failed';
    case FailReason.sanityCheck:
      return 'Pose out of range — sign mismatched?';
  }
}

class FrameFeatures {
  /// Pixel coordinates of each kept keypoint in the live frame.
  final List<cv.KeyPoint> keypoints;

  /// K × 32 byte ORB descriptors (CV_8UC1 Mat).
  final cv.Mat descriptors;

  /// Laplacian variance over the whole frame — used by the blur gate.
  final double laplacianVariance;

  /// Live frame dimensions in pixels.
  final int width;
  final int height;

  FrameFeatures({
    required this.keypoints,
    required this.descriptors,
    required this.laplacianVariance,
    required this.width,
    required this.height,
  });

  void dispose() {
    descriptors.dispose();
  }
}

class LocalizationResult {
  final Vector3? signFramePos;
  final Vector3? mallPosition;
  final double? mallHeadingDeg;
  final double confidence; // 0..1
  final int inlierCount;
  final int goodMatchCount;
  final FailReason? failReason;

  const LocalizationResult({
    this.signFramePos,
    this.mallPosition,
    this.mallHeadingDeg,
    required this.confidence,
    required this.inlierCount,
    required this.goodMatchCount,
    this.failReason,
  });

  bool get isSuccess => failReason == null && mallPosition != null;

  factory LocalizationResult.failure(FailReason reason,
          {int inliers = 0, int matches = 0}) =>
      LocalizationResult(
        confidence: 0,
        inlierCount: inliers,
        goodMatchCount: matches,
        failReason: reason,
      );
}

class LocalizationService {
  cv.ORB? _orb;
  cv.BFMatcher? _matcher;

  /// Pre-create ORB + BFMatcher so the first scan doesn't pay the
  /// allocation cost. Idempotent.
  void warmup() {
    _orb ??= cv.ORB.create(
      nFeatures: _orbNFeatures,
      scaleFactor: _orbScaleFactor,
      nLevels: _orbNLevels,
      edgeThreshold: _orbEdgeThreshold,
    );
    _matcher ??= cv.BFMatcher.create(type: cv.NORM_HAMMING, crossCheck: false);
    log('warmup complete', name: 'LOC');
  }

  void dispose() {
    _orb?.dispose();
    _matcher?.dispose();
    _orb = null;
    _matcher = null;
  }

  // ── Step 1–3: JPEG → ORB features ─────────────────────────────

  /// Returns null on decode failure (caller should map to FailReason).
  FrameFeatures? extractFeatures(Uint8List jpegBytes) {
    warmup();

    final gray = cv.imdecode(jpegBytes, cv.IMREAD_GRAYSCALE);
    if (gray.isEmpty) {
      gray.dispose();
      return null;
    }

    final laplacianVar = _laplacianVariance(gray);
    final w = gray.cols;
    final h = gray.rows;

    final (allKpsVec, allDescMat) = _orb!.detectAndCompute(gray, cv.Mat.empty());
    final allKps = allKpsVec.toList();
    if (allKps.isEmpty) {
      allDescMat.dispose();
      gray.dispose();
      return FrameFeatures(
        keypoints: const [],
        descriptors: cv.Mat.empty(),
        laplacianVariance: laplacianVar,
        width: w,
        height: h,
      );
    }

    // Keep top-K by response. ORB doesn't guarantee sorted output.
    final indexed = List<int>.generate(allKps.length, (i) => i);
    indexed.sort((a, b) => allKps[b].response.compareTo(allKps[a].response));
    final keep = indexed.take(_keepTopK).toList();

    final keptKps = [for (final i in keep) allKps[i]];
    final keptDesc = _selectDescriptorRows(allDescMat, keep);

    allDescMat.dispose();
    gray.dispose();

    return FrameFeatures(
      keypoints: keptKps,
      descriptors: keptDesc,
      laplacianVariance: laplacianVar,
      width: w,
      height: h,
    );
  }

  // ── Step 4–10: match + homography + solvePnP + transform ─────

  LocalizationResult matchAndLocalize({
    required FrameFeatures frame,
    required ShopFeatures target,
    required Shop shopData,
    required CameraIntrinsics intrinsics,
  }) {
    warmup();

    if (frame.laplacianVariance < _blurLaplacianThreshold) {
      log('REJECT: blurry frame, laplacianVar=${frame.laplacianVariance.toStringAsFixed(1)} '
          '< $_blurLaplacianThreshold', name: 'LOC');
      return LocalizationResult.failure(FailReason.blurryFrame);
    }
    if (frame.keypoints.isEmpty) {
      return LocalizationResult.failure(FailReason.noKeypoints);
    }

    // Build a Mat from the SSF1 descriptor blob (K rows × 32 cols, CV_8UC1).
    final trainDesc = _descriptorsMatFromBytes(target.descriptors,
        rows: target.keypoints.length, cols: 32);

    cv.Mat? srcMat;
    cv.Mat? dstMat;
    cv.Mat? homography;
    cv.Mat? mask;
    cv.Mat? cornersInImage;
    cv.Mat? objMat;
    cv.Mat? rvec;
    cv.Mat? tvec;
    cv.Mat? cameraMatrix;
    cv.Mat? distCoeffs;
    cv.Mat? rotMat;

    try {
      // ── Lowe's ratio test ──
      final knn = _matcher!.knnMatch(frame.descriptors, trainDesc, 2);
      final goodMatches = <cv.DMatch>[];
      for (final pair in knn) {
        if (pair.length < 2) continue;
        final m = pair[0];
        final n = pair[1];
        if (m.distance < _loweRatio * n.distance) {
          goodMatches.add(m);
        }
      }
      log('matches: ${goodMatches.length} good (of ${knn.length} knn pairs)',
          name: 'LOC');

      if (goodMatches.length < _minGoodMatches) {
        return LocalizationResult.failure(FailReason.lowMatches,
            matches: goodMatches.length);
      }

      // ── Homography (sign-normalized → image-pixel) ──
      final srcPts = <cv.Point2f>[]; // train (sign-norm)
      final dstPts = <cv.Point2f>[]; // query (image-px)
      for (final m in goodMatches) {
        final tk = target.keypoints[m.trainIdx];
        final qk = frame.keypoints[m.queryIdx];
        srcPts.add(cv.Point2f(tk.xNorm, tk.yNorm));
        dstPts.add(cv.Point2f(qk.x, qk.y));
      }
      final srcVec = cv.VecPoint2f.fromList(srcPts);
      final dstVec = cv.VecPoint2f.fromList(dstPts);
      srcMat = cv.Mat.fromVec(srcVec);
      dstMat = cv.Mat.fromVec(dstVec);
      mask = cv.Mat.empty();
      homography = cv.findHomography(
        srcMat,
        dstMat,
        method: cv.RANSAC,
        ransacReprojThreshold: _ransacReprojThreshold,
        mask: mask,
      );
      srcVec.dispose();
      dstVec.dispose();
      for (final p in srcPts) {
        p.dispose();
      }
      for (final p in dstPts) {
        p.dispose();
      }

      if (homography.isEmpty || homography.rows != 3 || homography.cols != 3) {
        return LocalizationResult.failure(FailReason.badHomography,
            matches: goodMatches.length);
      }

      final inliers = _countMaskInliers(mask);
      log('homography inliers: $inliers / ${goodMatches.length}', name: 'LOC');
      if (inliers < _minInliers) {
        return LocalizationResult.failure(FailReason.lowInliers,
            inliers: inliers, matches: goodMatches.length);
      }

      // ── Warp the canonical sign rectangle corners to image pixels ──
      // Sign-normalized corners: (0,0)=TL, (1,0)=TR, (1,1)=BR, (0,1)=BL.
      final cornersList = [
        cv.Point2f(0, 0),
        cv.Point2f(1, 0),
        cv.Point2f(1, 1),
        cv.Point2f(0, 1),
      ];
      final cornersNormVec = cv.VecPoint2f.fromList(cornersList);
      final cornersNormMat = cv.Mat.fromVec(cornersNormVec);
      cornersInImage = cv.perspectiveTransform(cornersNormMat, homography);
      cornersNormVec.dispose();
      cornersNormMat.dispose();
      for (final p in cornersList) {
        p.dispose();
      }

      // ── solvePnP ──
      // Object points in sign frame, meters. Origin at sign center,
      // +X right, +Y up, +Z out of sign face. Order matches cornersNormVec.
      final w = target.signWidthM;
      final h = target.signHeightM;
      final objPts = [
        cv.Point3f(-w / 2, h / 2, 0),
        cv.Point3f(w / 2, h / 2, 0),
        cv.Point3f(w / 2, -h / 2, 0),
        cv.Point3f(-w / 2, -h / 2, 0),
      ];
      final objVec = cv.VecPoint3f.fromList(objPts);
      objMat = cv.Mat.fromVec(objVec);
      objVec.dispose();
      for (final p in objPts) {
        p.dispose();
      }

      cameraMatrix = _cameraMatrix(intrinsics);
      distCoeffs = cv.Mat.zeros(1, 5, cv.MatType.CV_64FC1);

      final solveResult = cv.solvePnP(
        objMat,
        cornersInImage,
        cameraMatrix,
        distCoeffs,
        flags: _solvePnpIppeSquare,
      );
      final ok = solveResult.$1;
      rvec = solveResult.$2;
      tvec = solveResult.$3;

      if (!ok) {
        return LocalizationResult.failure(FailReason.solvePnpFailed,
            inliers: inliers, matches: goodMatches.length);
      }

      // ── Convert pose to user position in sign frame ──
      // tvec is the sign-origin position expressed in the camera frame.
      // The camera position in the sign frame is -R^T * t, where R is
      // the rotation that takes sign → camera.
      rotMat = cv.Rodrigues(rvec);

      final tx = _matAt(tvec, 0, 0);
      final ty = _matAt(tvec, 1, 0);
      final tz = _matAt(tvec, 2, 0);

      // R is 3x3, row-major. Camera-in-sign = -R^T * t.
      final r = List<List<double>>.generate(
        3,
        (i) => List<double>.generate(3, (j) => _matAt(rotMat!, i, j)),
      );
      final camInSignX = -(r[0][0] * tx + r[1][0] * ty + r[2][0] * tz);
      final camInSignY = -(r[0][1] * tx + r[1][1] * ty + r[2][1] * tz);
      final camInSignZ = -(r[0][2] * tx + r[1][2] * ty + r[2][2] * tz);
      final signFramePos = Vector3(camInSignX, camInSignY, camInSignZ);

      // Sanity: distance from sign and approximate height.
      final dist = signFramePos.distanceTo(const Vector3(0, 0, 0));
      if (dist < _minDistanceM || dist > _maxDistanceM) {
        log('REJECT: distance $dist out of [$_minDistanceM, $_maxDistanceM]',
            name: 'LOC');
        return LocalizationResult.failure(FailReason.sanityCheck,
            inliers: inliers, matches: goodMatches.length);
      }

      // Apply doorstep + facing-angle transform.
      final mallPos = geom.signFrameToMallFrame(signFramePos, shopData);

      if (mallPos.y < _minHeightM || mallPos.y > _maxHeightM) {
        log('REJECT: y=${mallPos.y} out of [$_minHeightM, $_maxHeightM]',
            name: 'LOC');
        return LocalizationResult.failure(FailReason.sanityCheck,
            inliers: inliers, matches: goodMatches.length);
      }

      // Heading: in sign frame, camera looks along -row[2] of R (the
      // sign→camera rotation). Project onto sign +X / +Z plane and
      // rotate into mall frame via the same theta as signFrameToMallFrame.
      final fwdSignX = -r[2][0];
      final fwdSignZ = -r[2][2];
      final theta = geom.degToRad(shopData.facingAngle - 90.0);
      final cTheta = math.cos(theta);
      final sTheta = math.sin(theta);
      final fwdMallX = fwdSignX * cTheta - fwdSignZ * sTheta;
      final fwdMallZ = fwdSignX * sTheta + fwdSignZ * cTheta;
      final headingDeg = geom.radToDeg(math.atan2(fwdMallZ, fwdMallX));

      final confidence = inliers / goodMatches.length.clamp(1, 1 << 30);

      log('★ FIX: signPos=$signFramePos mallPos=$mallPos '
          'heading=${headingDeg.toStringAsFixed(1)}° '
          'inliers=$inliers/${goodMatches.length}', name: 'LOC');

      return LocalizationResult(
        signFramePos: signFramePos,
        mallPosition: mallPos,
        mallHeadingDeg: headingDeg,
        confidence: confidence,
        inlierCount: inliers,
        goodMatchCount: goodMatches.length,
      );
    } finally {
      trainDesc.dispose();
      srcMat?.dispose();
      dstMat?.dispose();
      homography?.dispose();
      mask?.dispose();
      cornersInImage?.dispose();
      objMat?.dispose();
      rvec?.dispose();
      tvec?.dispose();
      cameraMatrix?.dispose();
      distCoeffs?.dispose();
      rotMat?.dispose();
    }
  }

  // ── Helpers ────────────────────────────────────────────────────

  double _laplacianVariance(cv.Mat gray) {
    final lap = cv.laplacian(gray, cv.MatType.CV_64FC1.value, ksize: 3);
    final (_, stddev) = cv.meanStdDev(lap);
    final std = stddev.val1;
    lap.dispose();
    return std * std;
  }

  cv.Mat _descriptorsMatFromBytes(Uint8List bytes,
      {required int rows, required int cols}) {
    if (rows == 0) return cv.Mat.empty();
    return cv.Mat.fromList(rows, cols, cv.MatType.CV_8UC1, bytes.toList());
  }

  cv.Mat _selectDescriptorRows(cv.Mat src, List<int> rowIdx) {
    if (rowIdx.isEmpty) return cv.Mat.empty();
    final rows = rowIdx.length;
    final cols = src.cols;
    final flat = <int>[];
    for (final r in rowIdx) {
      for (int c = 0; c < cols; c++) {
        flat.add(src.atNum(r, c).toInt());
      }
    }
    return cv.Mat.fromList(rows, cols, cv.MatType.CV_8UC1, flat);
  }

  cv.Mat _cameraMatrix(CameraIntrinsics i) {
    return cv.Mat.fromList(3, 3, cv.MatType.CV_64FC1, [
      i.fx, 0.0, i.cx,
      0.0, i.fy, i.cy,
      0.0, 0.0, 1.0,
    ]);
  }

  int _countMaskInliers(cv.Mat mask) {
    if (mask.isEmpty) return 0;
    int n = 0;
    for (int r = 0; r < mask.rows; r++) {
      for (int c = 0; c < mask.cols; c++) {
        if (mask.atNum(r, c).toInt() != 0) n++;
      }
    }
    return n;
  }

  double _matAt(cv.Mat m, int r, int c) => m.atNum(r, c).toDouble();
}
