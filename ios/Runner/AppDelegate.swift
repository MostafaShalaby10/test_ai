import ARKit
import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()

    let intrinsicsChannel = FlutterMethodChannel(
      name: "mall_nav/camera_intrinsics", binaryMessenger: messenger)
    intrinsicsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "getIntrinsics":
        let args = call.arguments as? [String: Any] ?? [:]
        let previewW = args["previewWidth"] as? Int ?? 0
        let previewH = args["previewHeight"] as? Int ?? 0
        if previewW <= 0 || previewH <= 0 {
          result(FlutterError(code: "bad_args",
            message: "previewWidth/previewHeight must be positive", details: nil))
          return
        }
        if let intr = self.computeIntrinsics(previewW: previewW, previewH: previewH) {
          result(intr)
        } else {
          result(FlutterError(code: "intrinsics_error",
            message: "No back camera available", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let arIntrinsicsChannel = FlutterMethodChannel(
      name: "mall_nav/ar_intrinsics", binaryMessenger: messenger)
    arIntrinsicsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "getARSnapshotIntrinsics":
        if let intr = self.computeARSnapshotIntrinsics() {
          result(intr)
        } else {
          result(FlutterError(code: "no_ar_view",
            message: "No active ARSCNView or no current AR frame", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Pinhole intrinsics matching the SCNView snapshot we feed to solvePnP
  /// in Tier 1. Derived from ARKit's projection matrix for the active
  /// viewport — this captures FOV, aspect cropping, AND device orientation,
  /// which the FOV-estimated fallback can't.
  ///
  /// Why we walk the window hierarchy: the AR view is owned by
  /// ar_flutter_plugin_2 which doesn't expose its session. Searching the
  /// window tree for an ARSCNView is intrusive but contained, and avoids
  /// patching the third-party plugin.
  private func computeARSnapshotIntrinsics() -> [String: Any]? {
    guard let arView = findARSCNView() else { return nil }
    guard let frame = arView.session.currentFrame else { return nil }
    let viewportPts = arView.bounds.size
    if viewportPts.width <= 0 || viewportPts.height <= 0 { return nil }

    let scale = arView.contentScaleFactor
    let viewportPx = CGSize(
      width: viewportPts.width * scale, height: viewportPts.height * scale)

    let orientation: UIInterfaceOrientation = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.interfaceOrientation ?? .portrait

    let projMatrix = frame.camera.projectionMatrix(
      for: orientation, viewportSize: viewportPts, zNear: 0.001, zFar: 1000.0)

    // ARKit's projection matrix has the standard OpenGL form:
    //   M[0,0] = 2*fx/W,         M[0,2] = (2*cx - W)/W = -1 + 2*cx/W
    //   M[1,1] = 2*fy/H,         M[1,2] = (H - 2*cy)/H = 1 - 2*cy/H
    // Solve back for fx/fy/cx/cy. We do this in PIXEL space (snapshot units)
    // so the intrinsics match the bytes we hand solvePnP.
    let W = Double(viewportPx.width)
    let H = Double(viewportPx.height)
    let m00 = Double(projMatrix.columns.0.x)
    let m11 = Double(projMatrix.columns.1.y)
    let m02 = Double(projMatrix.columns.2.x)
    let m12 = Double(projMatrix.columns.2.y)

    let fx = m00 * W / 2.0
    let fy = m11 * H / 2.0
    let cx = W * (m02 + 1.0) / 2.0
    let cy = H * (1.0 - m12) / 2.0

    return [
      "fx": fx, "fy": fy, "cx": cx, "cy": cy,
      "width": Int(W), "height": Int(H),
    ]
  }

  private func findARSCNView() -> ARSCNView? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let found = recursiveSearchARSCNView(in: window) { return found }
      }
    }
    return nil
  }

  private func recursiveSearchARSCNView(in view: UIView) -> ARSCNView? {
    if let arView = view as? ARSCNView { return arView }
    for sub in view.subviews {
      if let found = recursiveSearchARSCNView(in: sub) { return found }
    }
    return nil
  }

  /// Derive pinhole intrinsics for the default back camera, scaled into
  /// the pixel space of the given preview size.
  ///
  /// iOS exposes true intrinsics only via CMSampleBuffer attachments when
  /// `isCameraIntrinsicMatrixDeliveryEnabled` is set on a capture connection.
  /// The Flutter `camera` plugin owns the session and doesn't expose that,
  /// so we approximate from `videoFieldOfView` (horizontal FOV in degrees).
  /// This is good to ~5% — better than guessing, worse than a real
  /// calibration. For mall localization at 2–5m we accept the error.
  private func computeIntrinsics(previewW: Int, previewH: Int) -> [String: Any]? {
    guard let device = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: .back
    ) else {
      return nil
    }

    let fovDeg = Double(device.activeFormat.videoFieldOfView)
    // If the OS didn't report an FOV (rare), fall back to a 60° estimate.
    let effectiveFov = fovDeg > 0.0 ? fovDeg : 60.0

    // focal_px = (width/2) / tan(fov/2)
    let halfFovRad = effectiveFov * .pi / 360.0
    let fx = Double(previewW) / (2.0 * tan(halfFovRad))
    // Assume square pixels — iOS video formats normalize pixel aspect.
    let fy = fx

    return [
      "fx": fx,
      "fy": fy,
      "cx": Double(previewW) / 2.0,
      "cy": Double(previewH) / 2.0,
      "width": previewW,
      "height": previewH,
    ]
  }
}
