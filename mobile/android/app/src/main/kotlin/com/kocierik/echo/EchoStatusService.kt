package com.kocierik.echo

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Android's Live Activity: a foreground service whose silent notification shows whether Echo
 * is listening, its battery and the speech waiting to sync. Without it Android stops the app,
 * and the Bluetooth link, soon after it leaves the screen.
 *
 * Driven by the "echo/live_activity" channel, as on iOS (live_activity_service.dart):
 * `update` while a wearable is paired, `end` when none is.
 */
class EchoStatusService : Service() {
    companion object {
        private const val TAG = "EchoStatus"
        private const val CHANNEL_ID = "echo_status"
        private const val NOTIFICATION_ID = 7001
        private const val EXTRA_STATUS = "status"
        private const val EXTRA_BATTERY = "battery"
        private const val EXTRA_PENDING = "pendingMinutes"

        @Volatile
        private var running = false

        fun listen(context: Context, messenger: BinaryMessenger) {
            MethodChannel(messenger, "echo/live_activity").setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        update(
                            context,
                            call.argument<String>(EXTRA_STATUS) ?: "offline",
                            call.argument<Int>(EXTRA_BATTERY) ?: -1,
                            call.argument<Int>(EXTRA_PENDING) ?: 0,
                        )
                        result.success(null)
                    }
                    "end" -> {
                        context.stopService(Intent(context, EchoStatusService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        private fun update(context: Context, status: String, battery: Int, pendingMinutes: Int) {
            if (running) {
                // Already in the foreground: only the notification changes
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.notify(NOTIFICATION_ID, notification(context, status, battery, pendingMinutes))
                return
            }
            // Android 12+ refuses a connected-device service without the Bluetooth permission
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val intent = Intent(context, EchoStatusService::class.java)
                .putExtra(EXTRA_STATUS, status)
                .putExtra(EXTRA_BATTERY, battery)
                .putExtra(EXTRA_PENDING, pendingMinutes)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                // Android 12+ does not start one from the background: the next update in
                // the foreground does
                Log.w(TAG, "Could not start the status service", error)
            }
        }

        private fun notification(
            context: Context,
            status: String,
            battery: Int,
            pendingMinutes: Int,
        ): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Echo status", NotificationManager.IMPORTANCE_LOW)
                        .apply {
                            description = "Whether Echo is listening, its battery and the " +
                                "speech waiting to sync."
                            setShowBadge(false)
                        }
                )
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val title = when (status) {
                "listening" -> "Echo is listening"
                "muted" -> "Echo is muted"
                else -> "Echo is offline"
            }
            val details = listOfNotNull(
                if (battery >= 0) "Battery $battery%" else null,
                if (pendingMinutes > 0) "$pendingMinutes min waiting to sync" else null,
            ).joinToString(" · ")
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return builder
                .setSmallIcon(R.drawable.ic_stat_echo)
                .setContentTitle(title)
                .setContentText(details.ifEmpty { null })
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification(
            this,
            intent?.getStringExtra(EXTRA_STATUS) ?: "offline",
            intent?.getIntExtra(EXTRA_BATTERY, -1) ?: -1,
            intent?.getIntExtra(EXTRA_PENDING, 0) ?: 0,
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (error: Exception) {
            Log.w(TAG, "Could not go to the foreground", error)
            stopSelf()
        }
        // Killed by Android: not restarted on its own, the app starts it again
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
