package com.example.bt_tracker

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {

    private val bluetoothReceiver = BluetoothReceiver()
    private var receiverRegistered = false

    // ── Flutter engine ────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cache the engine so LocationCaptureService can push "locationUpdated"
        // events even when it starts from a background context.
        FlutterEngineCache.getInstance().put(TrackerPlugin.ENGINE_ID, flutterEngine)

        // Set up the single MethodChannel via TrackerPlugin.
        TrackerPlugin.setupChannel(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    // ── Activity lifecycle ────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestRuntimePermissions()
    }

    override fun onResume() {
        super.onResume()
        // Dynamic registration as belt-and-suspenders for the static manifest
        // receiver. Both share the same BluetoothReceiver instance so the
        // companion-object debounce prevents duplicate service starts.
        if (!receiverRegistered) {
            val filter = IntentFilter(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            registerReceiver(bluetoothReceiver, filter)
            receiverRegistered = true
        }
    }

    override fun onPause() {
        super.onPause()
        if (receiverRegistered) {
            try { unregisterReceiver(bluetoothReceiver) } catch (_: IllegalArgumentException) {}
            receiverRegistered = false
        }
    }

    override fun onDestroy() {
        FlutterEngineCache.getInstance().remove(TrackerPlugin.ENGINE_ID)
        super.onDestroy()
    }

    // ── Runtime permissions ───────────────────────────────────────────────────

    private fun requestRuntimePermissions() {
        val needed = buildList {
            if (ContextCompat.checkSelfPermission(this@MainActivity,
                    Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED)
                add(Manifest.permission.ACCESS_FINE_LOCATION)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (ContextCompat.checkSelfPermission(this@MainActivity,
                        Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                    add(Manifest.permission.BLUETOOTH_CONNECT)
                if (ContextCompat.checkSelfPermission(this@MainActivity,
                        Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED)
                    add(Manifest.permission.BLUETOOTH_SCAN)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(this@MainActivity,
                        Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                    add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        if (needed.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, needed.toTypedArray(), 0)
        }
    }
}
