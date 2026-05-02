package com.example.test_sensors

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Log
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val intrinsicsChannelName = "mall_nav/camera_intrinsics"
    private val arIntrinsicsChannelName = "mall_nav/ar_intrinsics"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, intrinsicsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getIntrinsics" -> {
                        val cameraId = call.argument<String>("cameraId") ?: "0"
                        val previewW = call.argument<Int>("previewWidth") ?: 0
                        val previewH = call.argument<Int>("previewHeight") ?: 0
                        if (previewW <= 0 || previewH <= 0) {
                            result.error(
                                "bad_args",
                                "previewWidth/previewHeight must be positive",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            val intrinsics = getIntrinsics(cameraId, previewW, previewH)
                            result.success(intrinsics)
                        } catch (t: Throwable) {
                            result.error(
                                "intrinsics_error",
                                t.message ?: "unknown",
                                null
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, arIntrinsicsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getARSnapshotIntrinsics" -> {
                        try {
                            val intr = computeARSnapshotIntrinsics()
                            if (intr != null) {
                                result.success(intr)
                            } else {
                                result.error(
                                    "no_ar_view",
                                    "No active ARSceneView or no current AR frame",
                                    null
                                )
                            }
                        } catch (t: Throwable) {
                            result.error(
                                "ar_intrinsics_error",
                                t.message ?: "unknown",
                                null
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Pinhole intrinsics for the AR snapshot, derived from ARCore's projection
     * matrix at the active view dimensions. Captures FOV, aspect cropping, and
     * device orientation correctly — the same numbers ARCore uses to render
     * the scene we just snapshotted.
     *
     * Why reflection: ar_flutter_plugin_2 owns the ARSceneView (sceneview lib)
     * and doesn't expose its session. Rather than adding a sceneview compile
     * dep here we walk the activity's view tree for an ARSceneView and pull
     * its currentFrame → underlying com.google.ar.core.Frame → projection
     * matrix via reflection. Same pattern as the iOS side
     * (UIWindowScene → ARSCNView).
     */
    private fun computeARSnapshotIntrinsics(): Map<String, Any>? {
        val arSceneView = findARSceneView() ?: run {
            Log.w("MallNavARIntrinsics", "ARSceneView not found in view hierarchy")
            return null
        }
        val width = arSceneView.width
        val height = arSceneView.height
        if (width <= 0 || height <= 0) {
            Log.w("MallNavARIntrinsics", "ARSceneView has zero size ${width}x$height")
            return null
        }

        // ARSceneView.currentFrame → io.github.sceneview.ar.arcore.ARFrame
        val arFrame = arSceneView.javaClass.methods
            .firstOrNull { it.name == "getCurrentFrame" && it.parameterCount == 0 }
            ?.invoke(arSceneView)
            ?: run {
                Log.w("MallNavARIntrinsics", "No current AR frame")
                return null
            }

        // ARFrame.frame → com.google.ar.core.Frame
        val frame = arFrame.javaClass.methods
            .firstOrNull { it.name == "getFrame" && it.parameterCount == 0 }
            ?.invoke(arFrame)
            ?: run {
                Log.w("MallNavARIntrinsics", "ARFrame has no underlying Frame")
                return null
            }

        // Frame.getCamera() → com.google.ar.core.Camera
        val arCamera = frame.javaClass.methods
            .firstOrNull { it.name == "getCamera" && it.parameterCount == 0 }
            ?.invoke(frame)
            ?: run {
                Log.w("MallNavARIntrinsics", "Frame has no Camera")
                return null
            }

        // Camera.getProjectionMatrix(dest, near, far)
        val proj = FloatArray(16)
        val getProjMatrix = arCamera.javaClass.methods
            .firstOrNull { it.name == "getProjectionMatrix" && it.parameterCount == 3 }
            ?: run {
                Log.w("MallNavARIntrinsics", "Camera has no getProjectionMatrix")
                return null
            }
        getProjMatrix.invoke(arCamera, proj, 0.001f, 1000.0f)

        // Standard OpenGL column-major projection matrix:
        //   M[0,0] = proj[0]  = 2*fx/W
        //   M[1,1] = proj[5]  = 2*fy/H
        //   M[0,2] = proj[8]  = (2*cx - W)/W = -1 + 2*cx/W
        //   M[1,2] = proj[9]  = (H - 2*cy)/H = 1 - 2*cy/H
        // Solve back for fx, fy, cx, cy in snapshot pixel space (sceneview's
        // width/height already match the bitmap PixelCopy produces).
        val m00 = proj[0].toDouble()
        val m11 = proj[5].toDouble()
        val m02 = proj[8].toDouble()
        val m12 = proj[9].toDouble()

        val w = width.toDouble()
        val h = height.toDouble()
        val fx = m00 * w / 2.0
        val fy = m11 * h / 2.0
        val cx = w * (m02 + 1.0) / 2.0
        val cy = h * (1.0 - m12) / 2.0

        Log.i(
            "MallNavARIntrinsics",
            "ARCore projection-derived intrinsics: " +
                "fx=$fx fy=$fy cx=$cx cy=$cy ${width}x$height"
        )

        return mapOf(
            "fx" to fx, "fy" to fy, "cx" to cx, "cy" to cy,
            "width" to width, "height" to height
        )
    }

    private fun findARSceneView(): View? {
        val rootView = window?.decorView ?: return null
        return findFirstViewByClassName(
            rootView, "io.github.sceneview.ar.ARSceneView"
        )
    }

    private fun findFirstViewByClassName(view: View, className: String): View? {
        if (view.javaClass.name == className) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFirstViewByClassName(view.getChildAt(i), className)?.let { return it }
            }
        }
        return null
    }

    /**
     * Compute pinhole intrinsics in the pixel space of the preview.
     *
     * Preferred path (API 23+): LENS_INTRINSIC_CALIBRATION gives
     * [fx, fy, cx, cy, s] directly in sensor-pixel space; we scale to preview.
     *
     * Fallback: derive fx, fy from physical focal length + sensor size.
     *   fx_active = focalLength_mm * sensorArrayWidth_px / sensorWidth_mm
     * Then scale from the active array to the preview resolution.
     */
    private fun getIntrinsics(
        cameraId: String,
        previewW: Int,
        previewH: Int
    ): Map<String, Any> {
        val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager

        // Resolve the camera — fall back to first back-facing if the given id is missing.
        val resolvedId = cm.cameraIdList.firstOrNull { it == cameraId }
            ?: cm.cameraIdList.firstOrNull {
                cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            }
            ?: cm.cameraIdList.first()

        val chars = cm.getCameraCharacteristics(resolvedId)

        val activeArray = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val activeW = activeArray?.width() ?: previewW
        val activeH = activeArray?.height() ?: previewH

        val sx = previewW.toDouble() / activeW.toDouble()
        val sy = previewH.toDouble() / activeH.toDouble()

        val intrinsicCalib: FloatArray? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                chars.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
            } else {
                null
            }

        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double

        if (intrinsicCalib != null && intrinsicCalib.size >= 5) {
            // [fx, fy, cx, cy, skew] in active-array pixel space.
            fx = intrinsicCalib[0].toDouble() * sx
            fy = intrinsicCalib[1].toDouble() * sy
            cx = intrinsicCalib[2].toDouble() * sx
            cy = intrinsicCalib[3].toDouble() * sy
            Log.i(
                "MallNavIntrinsics",
                "Using LENS_INTRINSIC_CALIBRATION for camera $resolvedId"
            )
        } else {
            // Fallback: derive from focal length (mm) + sensor physical size (mm).
            val focalLengths =
                chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            val focalMm = focalLengths?.firstOrNull()?.toDouble() ?: 4.0
            val sensorSize =
                chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            val sensorW = sensorSize?.width?.toDouble() ?: 5.7
            val sensorH = sensorSize?.height?.toDouble() ?: 4.3

            val fxActive = focalMm * activeW.toDouble() / sensorW
            val fyActive = focalMm * activeH.toDouble() / sensorH

            fx = fxActive * sx
            fy = fyActive * sy
            cx = previewW / 2.0
            cy = previewH / 2.0
            Log.i(
                "MallNavIntrinsics",
                "Derived intrinsics from focal+sensor size for camera $resolvedId " +
                    "(focal=${focalMm}mm, sensor=${sensorW}x${sensorH}mm, " +
                    "activeArray=${activeW}x$activeH)"
            )
        }

        return mapOf(
            "fx" to fx,
            "fy" to fy,
            "cx" to cx,
            "cy" to cy,
            "width" to previewW,
            "height" to previewH
        )
    }
}
