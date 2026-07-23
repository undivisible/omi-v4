package com.omi.omi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Holds the app process alive while the pendant is capturing.
 *
 * BLE notifications, the Rust hub and the write-ahead log all live in the main
 * process; without a foreground service Android is free to reclaim it as soon
 * as the activity leaves the screen, which is exactly when a wearable capture
 * app must not stop. The notification is not optional and is not a product
 * decision: Android requires it, and it doubles as the honest signal that the
 * app is recording.
 */
class CaptureForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val deviceName = intent?.getStringExtra(EXTRA_DEVICE_NAME) ?: "Omi"
        startForeground(NOTIFICATION_ID, buildNotification(deviceName))
        // Not START_STICKY: a restarted service with no Flutter engine behind
        // it would show a capture notification while nothing is capturing.
        return START_NOT_STICKY
    }

    private fun buildNotification(deviceName: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Capture",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "Shown while Omi is relaying audio from your pendant."
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Omi is capturing")
            .setContentText("Relaying audio from $deviceName.")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .apply { if (pending != null) setContentIntent(pending) }
            .build()
    }

    companion object {
        const val ACTION_STOP = "com.omi.omi.CAPTURE_STOP"
        const val EXTRA_DEVICE_NAME = "deviceName"
        private const val CHANNEL_ID = "omi_capture"
        private const val NOTIFICATION_ID = 4201
    }
}
