package com.example.test_sensors

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val intrinsicsChannelName = "mall_nav/camera_intrinsics"

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
