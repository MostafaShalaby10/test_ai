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

    let channel = FlutterMethodChannel(
      name: "mall_nav/camera_intrinsics",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "getIntrinsics":
        let args = call.arguments as? [String: Any] ?? [:]
        let previewW = args["previewWidth"] as? Int ?? 0
        let previewH = args["previewHeight"] as? Int ?? 0
        if previewW <= 0 || previewH <= 0 {
          result(
            FlutterError(
              code: "bad_args",
              message: "previewWidth/previewHeight must be positive",
              details: nil))
          return
        }
        if let intr = self.computeIntrinsics(previewW: previewW, previewH: previewH) {
          result(intr)
        } else {
          result(
            FlutterError(
              code: "intrinsics_error",
              message: "No back camera available",
              details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
