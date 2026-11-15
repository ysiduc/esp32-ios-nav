package com.esp32nav.app.mobile_app

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class EspNotificationListenerService : NotificationListenerService() {

    companion object {
        @Volatile
        var instance: EspNotificationListenerService? = null

        @Volatile
        var cachedTitle: String = ""
        @Volatile
        var cachedArtist: String = ""
        @Volatile
        var cachedIsPlaying: Boolean = false
        @Volatile
        var cachedDurationSec: Int = 0
        @Volatile
        var cachedElapsedSec: Int = 0
        @Volatile
        var lastPositionUpdateElapsedRealtime: Long = 0L

        fun getCurrentMediaMap(): Map<String, Any> {
            instance?.refreshMediaSessionsInternal(pushUpdate = false)
            var currentElapsed = cachedElapsedSec
            if (cachedIsPlaying && lastPositionUpdateElapsedRealtime > 0L) {
                val deltaSec = ((SystemClock.elapsedRealtime() - lastPositionUpdateElapsedRealtime) / 1000L).toInt()
                if (deltaSec > 0) {
                    currentElapsed = if (cachedDurationSec > 0) {
                        (cachedElapsedSec + deltaSec).coerceAtMost(cachedDurationSec)
                    } else {
                        cachedElapsedSec + deltaSec
                    }
                }
            }
            return mapOf(
                "title" to cachedTitle,
                "artist" to cachedArtist,
                "isPlaying" to cachedIsPlaying,
                "duration" to cachedDurationSec,
                "elapsedTime" to currentElapsed
            )
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaSessionManager: MediaSessionManager? = null
    private val activeControllers = mutableListOf<MediaController>()
    private var lastNotificationSignature: String = ""
    private var lastNotificationTimeMs: Long = 0L
    private var activeCallNotificationKey: String? = null

    private val sessionsChangedListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        registerControllers(controllers)
    }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            refreshMediaSessionsInternal(pushUpdate = true)
        }

        override fun onPlaybackStateChanged(state: PlaybackState?) {
            refreshMediaSessionsInternal(pushUpdate = true)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        unregisterControllers()
        try {
            mediaSessionManager?.removeOnActiveSessionsChangedListener(sessionsChangedListener)
        } catch (_: Throwable) {}
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        setupMediaSessionTracking()
    }

    override fun onListenerDisconnected() {
        unregisterControllers()
        super.onListenerDisconnected()
    }

    private fun setupMediaSessionTracking() {
        try {
            val mgr = getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager ?: return
            mediaSessionManager = mgr
            val comp = ComponentName(this, EspNotificationListenerService::class.java)
            mgr.addOnActiveSessionsChangedListener(sessionsChangedListener, comp, mainHandler)
            val controllers = mgr.getActiveSessions(comp)
            registerControllers(controllers)
        } catch (_: SecurityException) {
            // Notification access not yet granted
        } catch (_: Throwable) {}
    }

    private fun registerControllers(controllers: List<MediaController>?) {
        unregisterControllers()
        if (controllers != null) {
            for (c in controllers) {
                try {
                    c.registerCallback(controllerCallback, mainHandler)
                    activeControllers.add(c)
                } catch (_: Throwable) {}
            }
        }
        refreshMediaSessionsInternal(pushUpdate = true)
    }

    private fun unregisterControllers() {
        for (c in activeControllers) {
            try {
                c.unregisterCallback(controllerCallback)
            } catch (_: Throwable) {}
        }
        activeControllers.clear()
    }

    fun refreshMediaSessionsInternal(pushUpdate: Boolean) {
        try {
            val mgr = mediaSessionManager
                ?: (getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager)
            val comp = ComponentName(this, EspNotificationListenerService::class.java)
            val controllers = mgr?.getActiveSessions(comp) ?: activeControllers
            if (controllers.isEmpty()) return

            // Prefer the controller currently playing, otherwise the first controller with metadata
            var chosen: MediaController? = controllers.firstOrNull {
                it.playbackState?.state == PlaybackState.STATE_PLAYING &&
                        it.metadata != null
            }
            if (chosen == null) {
                chosen = controllers.firstOrNull { it.metadata != null }
            }
            if (chosen == null) return

            val meta = chosen.metadata
            val pb = chosen.playbackState

            val title = (meta?.getString(MediaMetadata.METADATA_KEY_TITLE)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
                ?: "").trim()
            val artist = (meta?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_AUTHOR)
                ?: "").trim()
            val durationMs = meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
            val durationSec = if (durationMs > 0L) (durationMs / 1000L).toInt() else 0

            val isPlaying = pb?.state == PlaybackState.STATE_PLAYING
            val posMs = pb?.position ?: 0L
            val elapsedSec = if (posMs > 0L) (posMs / 1000L).toInt() else 0

            val changed = title != cachedTitle ||
                    artist != cachedArtist ||
                    isPlaying != cachedIsPlaying ||
                    durationSec != cachedDurationSec

            cachedTitle = title
            cachedArtist = artist
            cachedIsPlaying = isPlaying
            cachedDurationSec = durationSec
            cachedElapsedSec = elapsedSec
            lastPositionUpdateElapsedRealtime = SystemClock.elapsedRealtime()

            if (pushUpdate && changed) {
                MainActivity.onNativeMediaUpdated(getCurrentMediaMap())
            }
        } catch (_: Throwable) {}
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName ?: return
        if (pkg == applicationContext.packageName || pkg == "android" || pkg == "com.android.systemui") {
            return
        }

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        // Also refresh media sessions if a media style notification arrived
        if (extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) {
            refreshMediaSessionsInternal(pushUpdate = true)
            return
        }

        val rawTitle = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
            ?: extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim()
            ?: ""
        val rawBigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        val rawText = (if (!rawBigText.isNullOrEmpty()) rawBigText
        else extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()) ?: ""

        if (rawTitle.isEmpty() && rawText.isEmpty()) return

        val category = notification.category ?: ""
        val isOngoing = (notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
        val isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        if (isGroupSummary) return

        // 1. Detect Incoming Calls (Carrier / Dialer / Zalo Call / Messenger Call)
        val lowerText = rawText.lowercase()
        val lowerTitle = rawTitle.lowercase()
        val isCallCategory = category == Notification.CATEGORY_CALL
        val isVoipRinging = (pkg.contains("zalo") || pkg.contains("orca") || pkg.contains("dialer") || pkg.contains("incallui") || pkg.contains("telecom")) &&
                (lowerText.contains("cuộc gọi đến") || lowerText.contains("đang gọi") || lowerText.contains("incoming call") || isCallCategory)

        if (isCallCategory || isVoipRinging) {
            activeCallNotificationKey = sbn.key
            val caller = if (rawTitle.isNotEmpty()) rawTitle else "Cuộc gọi đến"
            val statusOrNumber = if (rawText.isNotEmpty()) rawText else "Đang đổ chuông..."
            MainActivity.onNativeIncomingCall(caller, statusOrNumber)
            return
        }

        // Ignore non-call ongoing foreground service notifications
        if (isOngoing) return

        // 2. Map package name to ESP32 notification app type ('zalo', 'messenger', 'sms', 'bell')
        val lowerPkg = pkg.lowercase()
        val appType = when {
            lowerPkg.contains("zalo") -> "zalo"
            lowerPkg.contains("facebook.orca") || lowerPkg.contains("facebook.mlite") || lowerPkg.contains("messenger") -> "messenger"
            lowerPkg.contains("mms") || lowerPkg.contains("messaging") || lowerPkg.contains("sms") ||
                    lowerPkg.contains("telegram") || lowerPkg.contains("whatsapp") || lowerPkg.contains("viber") -> "sms"
            else -> "sms"
        }

        // Deduplicate identical notifications within 2.5 seconds
        val now = System.currentTimeMillis()
        val sig = "$appType|$rawTitle|$rawText"
        if (sig == lastNotificationSignature && (now - lastNotificationTimeMs) < 2500L) {
            return
        }
        lastNotificationSignature = sig
        lastNotificationTimeMs = now

        val cleanTitle = if (rawTitle.isNotEmpty()) rawTitle else appType.uppercase()
        val cleanMsg = if (rawText.isNotEmpty()) rawText else rawTitle
        MainActivity.onNativeIncomingNotification(appType, cleanTitle, cleanMsg)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (activeCallNotificationKey != null && sbn.key == activeCallNotificationKey) {
            activeCallNotificationKey = null
            MainActivity.onNativeCallEnded()
        }
        if (sbn.notification?.extras?.containsKey(Notification.EXTRA_MEDIA_SESSION) == true) {
            refreshMediaSessionsInternal(pushUpdate = true)
        }
    }
}

