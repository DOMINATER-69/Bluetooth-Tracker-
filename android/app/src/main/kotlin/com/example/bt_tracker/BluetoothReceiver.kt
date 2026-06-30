package com.example.bt_tracker

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class BluetoothReceiver : BroadcastReceiver() {

    companion object {
        private const val DEBOUNCE_MS = 4_000L
        private const val WAKELOCK_TIMEOUT_MS = 30_000L
        private const val WAKELOCK_TAG = "BtTracker:ReceiverWL"

        // Thread-safe debounce state
        private val lastDisconnectTime = AtomicLong(0L)
        private val lastDisconnectedAddress = AtomicReference<String?>(null)

        // Static WakeLock bridging receiver→service startup gap
        @Volatile private var wakeLock: PowerManager.WakeLock? = null

        fun acquireWakeLock(context: Context) {
            val pm = context.applicationContext.getSystemService(Context.POWER_SERVICE)
                    as PowerManager
            synchronized(this) {
                wakeLock?.let { if (it.isHeld) it.release() }
                val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG)
                wl.setReferenceCounted(false)
                wl.acquire(WAKELOCK_TIMEOUT_MS)
                wakeLock = wl
            }
        }

        fun releaseWakeLock() {
            synchronized(this) {
                wakeLock?.let { if (it.isHeld) it.release() }
                wakeLock = null
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BluetoothDevice.ACTION_ACL_DISCONNECTED) return

        val address: String = try {
            val device: BluetoothDevice? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(
                        BluetoothDevice.EXTRA_DEVICE,
                        BluetoothDevice::class.java
                    )
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                }
            device?.address ?: return
        } catch (_: SecurityException) {
            // BLUETOOTH_CONNECT not yet granted; use a constant key for debounce
            "unknown"
        }

        val now = SystemClock.elapsedRealtime()
        val prev = lastDisconnectTime.get()
        val prevAddr = lastDisconnectedAddress.get()

        if (address == prevAddr && now - prev < DEBOUNCE_MS) return

        lastDisconnectTime.set(now)
        lastDisconnectedAddress.set(address)

        // Acquire WakeLock BEFORE returning from onReceive so the CPU stays
        // awake long enough for the service to start and acquire its own lock.
        acquireWakeLock(context)

        val serviceIntent = Intent(context, LocationCaptureService::class.java)
            .putExtra(LocationCaptureService.EXTRA_DEVICE_ADDRESS, address)
        context.startForegroundService(serviceIntent)
    }
}
