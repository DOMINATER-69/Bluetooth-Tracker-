package com.example.bt_tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource

class LocationCaptureService : Service() {

    companion object {
        const val EXTRA_DEVICE_ADDRESS = "device_address"

        private const val CHANNEL_ID          = "bt_tracker_loc"
        private const val NOTIFICATION_ID     = 1001
        private const val MAX_LAST_KNOWN_AGE  = 5 * 60 * 1000L   // 5 min
        private const val MAX_ACCURACY_LAST   = 150f              // metres
        private const val MAX_ACCURACY_FRESH  = 80f               // metres
        private const val LOCATION_TIMEOUT_MS = 15_000L           // 15 s
        private const val WAKELOCK_TAG        = "BtTracker:ServiceWL"
    }

    private val fusedClient by lazy {
        LocationServices.getFusedLocationProviderClient(this)
    }

    private var cancellationTokenSource: CancellationTokenSource? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var stopCalled = false

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Release the receiver's bridging WakeLock now that we are running.
        BluetoothReceiver.releaseWakeLock()

        startForeground(NOTIFICATION_ID, buildNotification())
        captureLocation()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        cancellationTokenSource?.cancel()
        cancellationTokenSource = null
        releaseWakeLock()
    }

    // ── Location capture ──────────────────────────────────────────────────────

    private fun captureLocation() {
        // Step 1 – try Fused last-known location (zero battery cost)
        try {
            @Suppress("MissingPermission")
            fusedClient.lastLocation
                .addOnSuccessListener { location ->
                    if (location != null
                        && isAgeFresh(location)
                        && location.accuracy <= MAX_ACCURACY_LAST
                    ) {
                        saveAndStop(location)
                    } else {
                        requestFreshLocation()
                    }
                }
                .addOnFailureListener { requestFreshLocation() }
                .addOnCanceledListener { stopSelfClean() }
        } catch (_: SecurityException) {
            stopSelfClean()
        }
    }

    private fun requestFreshLocation() {
        val cts = CancellationTokenSource().also { cancellationTokenSource = it }

        val request = CurrentLocationRequest.Builder()
            .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            .setDurationMillis(LOCATION_TIMEOUT_MS)
            .setMaxUpdateAgeMillis(60_000L)
            .build()

        try {
            @Suppress("MissingPermission")
            fusedClient.getCurrentLocation(request, cts.token)
                .addOnSuccessListener { location ->
                    if (location != null && location.accuracy <= MAX_ACCURACY_FRESH) {
                        saveAndStop(location)
                    } else if (location != null) {
                        // Accuracy is poor but it is the best we got inside the timeout
                        saveAndStop(location)
                    } else {
                        stopSelfClean()
                    }
                }
                .addOnFailureListener { stopSelfClean() }
                .addOnCanceledListener { stopSelfClean() }
        } catch (_: SecurityException) {
            stopSelfClean()
        }
    }

    // ── Save & stop ───────────────────────────────────────────────────────────

    private fun saveAndStop(location: Location) {
        val filePath = "${filesDir.absolutePath}/last_location.bin"
        TrackerPlugin.nativeSaveLastLocation(
            location.latitude,
            location.longitude,
            System.currentTimeMillis(),
            filePath
        )
        TrackerPlugin.notifyLocationUpdated(this)
        stopSelfClean()
    }

    private fun stopSelfClean() {
        if (stopCalled) return
        stopCalled = true
        cancellationTokenSource?.cancel()
        cancellationTokenSource = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        // WakeLock released in onDestroy()
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun isAgeFresh(location: Location): Boolean =
        System.currentTimeMillis() - location.time < MAX_LAST_KNOWN_AGE

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(LOCATION_TIMEOUT_MS + 5_000L)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "BT Tracker",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Saving location after earbud disconnect"
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("BT Tracker")
            .setContentText("Capturing last location…")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
}
