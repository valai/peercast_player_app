package jp.valaishasu.pecaone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Keeps the in-process PeerCast worker and player alive while viewing. */
class PlaybackService : Service() {
    companion object {
        const val STOP = "jp.valaishasu.pecaone.STOP_PLAYBACK"
        private const val CHANNEL = "playback"
        private const val NOTIFICATION = 7144
        var running = false
            private set
        var onStarted: ((Boolean) -> Unit)? = null
        var onStop: (() -> Unit)? = null
        var onLost: (() -> Unit)? = null
        var intentionalStop = false
    }

    private var cpu: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var expectedStop = false

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            expectedStop = true
            onStop?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            intentionalStop = false
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL, "視聴・リレー", NotificationManager.IMPORTANCE_LOW
                ))
            }
            val open = PendingIntent.getActivity(this, 0,
                Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val stop = PendingIntent.getService(this, 1,
                Intent(this, PlaybackService::class.java).setAction(STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
                          else Notification.Builder(this)
            val notification = builder
                .setSmallIcon(R.drawable.ic_playback_notification)
                .setContentTitle(intent?.getStringExtra("title") ?: "ぺかわん")
                .setContentText("視聴・リレー中")
                .setContentIntent(open)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .addAction(Notification.Action.Builder(null, "停止", stop).build())
                .build()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION, notification)
            }
            if (cpu == null) {
                cpu = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pecaone:playback")
                    .apply { setReferenceCounted(false); acquire() }
                wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
                    .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "pecaone:relay")
                    .apply { setReferenceCounted(false); acquire() }
            }
            running = true
            onStarted?.invoke(true)
        } catch (_: Exception) {
            onStarted?.invoke(false)
            stopSelf()
        }
        onStarted = null
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        expectedStop = true
        onStop?.invoke()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        val wasRunning = running
        running = false
        wifi?.let { if (it.isHeld) it.release() }
        cpu?.let { if (it.isHeld) it.release() }
        wifi = null
        cpu = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (wasRunning && !expectedStop && !intentionalStop) onLost?.invoke()
        super.onDestroy()
    }
}
