package com.example.bt_tracker

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Single owner of the native "tracker" library.
 *
 * Rules:
 *  - System.loadLibrary is called exactly once, here.
 *  - All JNI declarations live here.
 *  - LocationCaptureService calls TrackerPlugin.native*() directly — never
 *    MainActivity.native*().
 *  - setupChannel() is called from MainActivity.configureFlutterEngine().
 *  - notifyLocationUpdated() is safe to call from any thread; it posts to the
 *    main thread automatically and is a no-op when Flutter is not alive.
 */
object TrackerPlugin {

    const val CHANNEL   = "com.example.bt_tracker/tracker"
    const val ENGINE_ID = "main_engine"

    init {
        System.loadLibrary("tracker")
    }

    // ── JNI declarations ──────────────────────────────────────────────────────

    @JvmStatic external fun nativeSaveLastLocation(
        lat: Double, lon: Double, timestamp: Long, filePath: String)

    @JvmStatic external fun nativeLoadLastLocation(filePath: String): DoubleArray

    @JvmStatic external fun nativeGetLastLocation(): DoubleArray

    @JvmStatic external fun nativeGetDistance(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double

    @JvmStatic external fun nativeGetBearing(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double

    @JvmStatic external fun nativeClearBreadcrumbs(filePath: String)

    @JvmStatic external fun nativeGetBreadcrumbCount(): Int

    // ── MethodChannel setup ───────────────────────────────────────────────────

    fun setupChannel(messenger: BinaryMessenger, context: Context) {
        val filePath = "${context.filesDir.absolutePath}/last_location.bin"

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {

                    "loadLastLocation" -> {
                        val arr = nativeLoadLastLocation(filePath)
                        result.success(
                            if (arr.size >= 3 && (arr[0] != 0.0 || arr[1] != 0.0))
                                mapOf("latitude" to arr[0],
                                      "longitude" to arr[1],
                                      "timestamp" to arr[2].toLong())
                            else null
                        )
                    }

                    "getLastLocation" -> {
                        val arr = nativeGetLastLocation()
                        result.success(
                            if (arr.size >= 3 && (arr[0] != 0.0 || arr[1] != 0.0))
                                mapOf("latitude" to arr[0],
                                      "longitude" to arr[1],
                                      "timestamp" to arr[2].toLong())
                            else null
                        )
                    }

                    "getDistance" -> {
                        val lat1 = call.argument<Double>("lat1") ?: 0.0
                        val lon1 = call.argument<Double>("lon1") ?: 0.0
                        val lat2 = call.argument<Double>("lat2") ?: 0.0
                        val lon2 = call.argument<Double>("lon2") ?: 0.0
                        result.success(nativeGetDistance(lat1, lon1, lat2, lon2))
                    }

                    "getBearing" -> {
                        val lat1 = call.argument<Double>("lat1") ?: 0.0
                        val lon1 = call.argument<Double>("lon1") ?: 0.0
                        val lat2 = call.argument<Double>("lat2") ?: 0.0
                        val lon2 = call.argument<Double>("lon2") ?: 0.0
                        result.success(nativeGetBearing(lat1, lon1, lat2, lon2))
                    }

                    "clearBreadcrumbs" -> {
                        nativeClearBreadcrumbs(filePath)
                        result.success(null)
                    }

                    "getBreadcrumbCount" -> {
                        result.success(nativeGetBreadcrumbCount())
                    }

                    "isBluetoothConnected" -> {
                        result.success(isBluetoothConnected(context))
                    }

                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("NATIVE_ERROR", e.message, null)
            }
        }
    }

    // ── Push notification to Flutter ──────────────────────────────────────────

    /**
     * Invoke "locationUpdated" on the Flutter side if the engine is alive.
     * Safe to call from any thread.
     */
    fun notifyLocationUpdated(context: Context) {
        Handler(Looper.getMainLooper()).post {
            val engine: FlutterEngine =
                FlutterEngineCache.getInstance().get(ENGINE_ID) ?: return@post
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("locationUpdated", null)
        }
    }

    // ── Bluetooth status ──────────────────────────────────────────────────────

    private fun isBluetoothConnected(context: Context): Boolean {
        return try {
            val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE)
                    as? android.bluetooth.BluetoothManager ?: return false
            val adapter = btManager.adapter ?: return false
            if (!adapter.isEnabled) return false
            @Suppress("MissingPermission")
            adapter.getProfileConnectionState(android.bluetooth.BluetoothProfile.HEADSET) ==
                    android.bluetooth.BluetoothProfile.STATE_CONNECTED
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }
}
