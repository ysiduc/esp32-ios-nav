package com.esp32nav.app.mobile_app

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Parcel
import android.os.Parcelable
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.RemoteViews
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.min

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

        const val GOOGLE_MAPS_PACKAGE = "com.google.android.apps.maps"

        @Volatile
        var cachedGoogleMapsNav: Map<String, Any>? = null

        fun rescanGoogleMapsNotification(): Map<String, Any>? {
            val svc = instance ?: return cachedGoogleMapsNav
            return svc.scanActiveGoogleMapsInternal(dispatchToFlutter = true)
        }

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
    private var activeGoogleMapsKey: String? = null
    private var lastGmapsSignature: String = ""
    private var lastGmapsSentMs: Long = 0L

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
        scanActiveGoogleMapsInternal(dispatchToFlutter = true)
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

        // Always intercept Google Maps notifications here (inspired by maisonsmd/esp32-google-maps)
        // so navigation updates never fall through into SMS popups and are forwarded cleanly.
        if (pkg == GOOGLE_MAPS_PACKAGE) {
            processGoogleMapsNotification(sbn, dispatchToFlutter = true)
            return
        }

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
        if (sbn.packageName == GOOGLE_MAPS_PACKAGE) {
            val remaining = scanActiveGoogleMapsInternal(dispatchToFlutter = true)
            if (remaining == null && (activeGoogleMapsKey == sbn.key || cachedGoogleMapsNav != null)) {
                activeGoogleMapsKey = null
                cachedGoogleMapsNav = null
                lastGmapsSignature = ""
                MainActivity.onNativeGoogleMapsNavEnded()
            }
            return
        }
        if (activeCallNotificationKey != null && sbn.key == activeCallNotificationKey) {
            activeCallNotificationKey = null
            MainActivity.onNativeCallEnded()
        }
        if (sbn.notification?.extras?.containsKey(Notification.EXTRA_MEDIA_SESSION) == true) {
            refreshMediaSessionsInternal(pushUpdate = true)
        }
    }

    private fun scanActiveGoogleMapsInternal(dispatchToFlutter: Boolean): Map<String, Any>? {
        try {
            val active = activeNotifications ?: return null
            for (sbn in active) {
                if (sbn.packageName == GOOGLE_MAPS_PACKAGE) {
                    val parsed = processGoogleMapsNotification(sbn, dispatchToFlutter = dispatchToFlutter)
                    if (parsed != null) return parsed
                }
            }
        } catch (_: Throwable) {}
        return null
    }

    private fun processGoogleMapsNotification(
        sbn: StatusBarNotification,
        dispatchToFlutter: Boolean
    ): Map<String, Any>? {
        val notification = sbn.notification ?: return null
        val isOngoing = (notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
        val isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        if (isGroupSummary) return null

        val category = notification.category ?: ""
        val isCategoryNav = category == Notification.CATEGORY_NAVIGATION
        val extras = notification.extras

        val title = (extras?.getCharSequence(Notification.EXTRA_TITLE)
            ?: extras?.getCharSequence(Notification.EXTRA_TITLE_BIG))?.toString()?.trim() ?: ""
        val text = (extras?.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.trim() ?: ""
        val bigText = (extras?.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString()?.trim() ?: ""
        val subText = (extras?.getCharSequence(Notification.EXTRA_SUB_TEXT))?.toString()?.trim() ?: ""
        val infoText = (extras?.getCharSequence(Notification.EXTRA_INFO_TEXT))?.toString()?.trim() ?: ""

        val remoteTexts = LinkedHashSet<String>()
        val namedTexts = LinkedHashMap<String, String>()
        val prioritizedBitmaps = ArrayList<Bitmap>()
        val secondaryBitmaps = ArrayList<Bitmap>()

        var targetCtx: Context = this
        try {
            targetCtx = createPackageContext(GOOGLE_MAPS_PACKAGE, Context.CONTEXT_IGNORE_SECURITY)
        } catch (_: Throwable) {}

        // 1. Standard Android / Google Maps turn icon slots first (largeIcon / EXTRA_LARGE_ICON*),
        //    so chrome/action icons in RemoteViews never shadow the real turn arrow.
        try {
            val largeIconObj = notification.getLargeIcon()
            val d = largeIconObj?.loadDrawable(targetCtx) ?: largeIconObj?.loadDrawable(this)
            val bmp = drawableToBitmap(d)
            if (bmp != null) prioritizedBitmaps.add(bmp)
        } catch (_: Throwable) {}
        try {
            if (extras != null) {
                extractBitmapExtra(extras, Notification.EXTRA_LARGE_ICON_BIG, targetCtx)?.let {
                    prioritizedBitmaps.add(it)
                }
                extractBitmapExtra(extras, Notification.EXTRA_LARGE_ICON, targetCtx)?.let {
                    prioritizedBitmaps.add(it)
                }
            }
        } catch (_: Throwable) {}

        // 2. Inflate Google Maps RemoteViews (bigContentView, contentView, headsUpContentView)
        //    to extract dynamic turn instruction rows & any maneuver ImageView bitmaps.
        val viewsToInspect = listOfNotNull(
            notification.bigContentView,
            notification.contentView,
            notification.headsUpContentView
        )
        for (rv in viewsToInspect) {
            extractFromRemoteViews(
                rv,
                targetCtx,
                remoteTexts,
                namedTexts,
                prioritizedBitmaps,
                secondaryBitmaps
            )
        }

        val candidateBitmaps = ArrayList<Bitmap>(prioritizedBitmaps.size + secondaryBitmaps.size).apply {
            addAll(prioritizedBitmaps)
            addAll(secondaryBitmaps)
        }

        val allTexts = LinkedHashSet<String>()
        if (title.isNotEmpty()) allTexts.add(title)
        if (text.isNotEmpty()) allTexts.add(text)
        if (bigText.isNotEmpty()) allTexts.add(bigText)
        allTexts.addAll(remoteTexts)
        if (subText.isNotEmpty()) allTexts.add(subText)
        if (infoText.isNotEmpty()) allTexts.add(infoText)

        // Filter out non-navigation Google Maps notifications (reviews, offline download, promo alerts)
        val hasCustomRemoteViews = notification.bigContentView != null || notification.contentView != null
        if (!isOngoing && !isCategoryNav && !hasCustomRemoteViews) {
            return null
        }
        if (allTexts.isEmpty()) {
            return null
        }

        var bitmapTurnCode = -1
        for (bmp in candidateBitmaps) {
            val classified = TurnArrowClassifier.classifyBitmap(bmp)
            if (classified >= 0) {
                bitmapTurnCode = classified
                break
            }
        }

        val payload = HashMap<String, Any>()
        payload["title"] = title
        payload["text"] = text
        payload["bigText"] = bigText
        payload["subText"] = subText
        payload["infoText"] = infoText
        payload["texts"] = allTexts.toList()
        payload["namedTexts"] = namedTexts
        payload["bitmapTurnCode"] = bitmapTurnCode
        payload["isOngoing"] = isOngoing
        payload["isCategoryNav"] = isCategoryNav
        payload["timestampMs"] = System.currentTimeMillis()

        activeGoogleMapsKey = sbn.key
        cachedGoogleMapsNav = payload

        if (dispatchToFlutter) {
            val sig = "$title|$text|$subText|${allTexts.joinToString("^")}|$bitmapTurnCode"
            val now = System.currentTimeMillis()
            if (sig != lastGmapsSignature || (now - lastGmapsSentMs) >= 1200L) {
                lastGmapsSignature = sig
                lastGmapsSentMs = now
                MainActivity.onNativeGoogleMapsNav(payload)
            }
        }
        return payload
    }

    private fun extractBitmapExtra(extras: android.os.Bundle, key: String, ctx: Context): Bitmap? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val bmp = extras.getParcelable(key, Bitmap::class.java)
                if (bmp != null) return bmp
                val icon = extras.getParcelable(key, Icon::class.java)
                drawableToBitmap(icon?.loadDrawable(ctx) ?: icon?.loadDrawable(this))
            } else {
                @Suppress("DEPRECATION")
                val obj = extras.getParcelable<Parcelable>(key)
                when (obj) {
                    is Bitmap -> obj
                    is Icon -> drawableToBitmap(obj.loadDrawable(ctx) ?: obj.loadDrawable(this))
                    else -> null
                }
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun extractFromRemoteViews(
        rv: RemoteViews,
        targetCtx: Context,
        outTexts: LinkedHashSet<String>,
        outNamedTexts: LinkedHashMap<String, String>,
        outPriorityBitmaps: MutableList<Bitmap>,
        outSecondaryBitmaps: MutableList<Bitmap>
    ) {
        var inflated = false
        try {
            val container = FrameLayout(targetCtx)
            val root = rv.apply(targetCtx, container)
            if (root != null) {
                walkViewHierarchy(
                    root,
                    targetCtx,
                    outTexts,
                    outNamedTexts,
                    outPriorityBitmaps,
                    outSecondaryBitmaps
                )
                inflated = true
            }
        } catch (_: Throwable) {}

        // Fallback to safe ReflectionAction string extraction if apply() failed
        if (!inflated || outTexts.isEmpty()) {
            try {
                val actionsField = rv.javaClass.getDeclaredField("mActions")
                actionsField.isAccessible = true
                @Suppress("UNCHECKED_CAST")
                val actions = actionsField.get(rv) as? ArrayList<Parcelable>
                if (actions != null) {
                    for (action in actions) {
                        val parcel = Parcel.obtain()
                        try {
                            action.writeToParcel(parcel, 0)
                            parcel.setDataPosition(0)
                            val tag = parcel.readInt()
                            if (tag == 2) {
                                val viewId = parcel.readInt()
                                val method = parcel.readString()
                                if (method == "setText") {
                                    parcel.readInt()
                                    val txt = parcel.readString()?.replace('\u00A0', ' ')?.trim()
                                    if (!txt.isNullOrEmpty()) {
                                        outTexts.add(txt)
                                        try {
                                            val name = targetCtx.resources.getResourceEntryName(viewId)
                                            if (name.isNotEmpty()) outNamedTexts[name] = txt
                                        } catch (_: Throwable) {}
                                    }
                                }
                            }
                        } catch (_: Throwable) {
                        } finally {
                            parcel.recycle()
                        }
                    }
                }
            } catch (_: Throwable) {}
        }
    }

    private fun walkViewHierarchy(
        view: View,
        targetCtx: Context,
        outTexts: LinkedHashSet<String>,
        outNamedTexts: LinkedHashMap<String, String>,
        outPriorityBitmaps: MutableList<Bitmap>,
        outSecondaryBitmaps: MutableList<Bitmap>
    ) {
        if (view.visibility == View.GONE || view.visibility == View.INVISIBLE) return
        if (view is android.widget.Button) return
        when (view) {
            is TextView -> {
                val txt = view.text?.toString()?.replace('\u00A0', ' ')?.trim()
                if (!txt.isNullOrEmpty()) {
                    outTexts.add(txt)
                    if (view.id != View.NO_ID) {
                        try {
                            val name = targetCtx.resources.getResourceEntryName(view.id)
                            if (name.isNotEmpty()) outNamedTexts[name] = txt
                        } catch (_: Throwable) {}
                    }
                }
            }
            is ImageView -> {
                val viewName = if (view.id != View.NO_ID) {
                    try {
                        targetCtx.resources.getResourceEntryName(view.id).lowercase()
                    } catch (_: Throwable) {
                        ""
                    }
                } else {
                    ""
                }
                if (isNonManeuverViewName(viewName)) return

                val bmp = drawableToBitmap(view.drawable, view.imageTintList?.defaultColor, view.colorFilter)
                if (bmp != null && bmp.width in 24..512 && bmp.height in 24..512) {
                    val ratio = maxOf(bmp.width, bmp.height).toFloat() /
                        min(bmp.width, bmp.height).coerceAtLeast(1).toFloat()
                    if (ratio <= 1.75f) {
                        if (isPreferredManeuverViewName(viewName) || (bmp.width >= 44 && bmp.height >= 44)) {
                            outPriorityBitmaps.add(bmp)
                        } else {
                            outSecondaryBitmaps.add(bmp)
                        }
                    }
                }
            }
            is ViewGroup -> {
                for (i in 0 until view.childCount) {
                    walkViewHierarchy(
                        view.getChildAt(i),
                        targetCtx,
                        outTexts,
                        outNamedTexts,
                        outPriorityBitmaps,
                        outSecondaryBitmaps
                    )
                }
            }
        }
    }

    private fun isNonManeuverViewName(name: String): Boolean {
        if (name.isEmpty()) return false
        val ignoreTokens = arrayOf(
            "close", "cancel", "dismiss", "exit", "mute", "sound", "volume",
            "search", "mic", "recenter", "logo", "badge", "app_icon",
            "small_icon", "action", "expand", "collapse"
        )
        return ignoreTokens.any { name.contains(it) }
    }

    private fun isPreferredManeuverViewName(name: String): Boolean {
        if (name.isEmpty()) return false
        val preferTokens = arrayOf("turn", "maneuver", "arrow", "direction", "guidance", "nav", "icon")
        return preferTokens.any { name.contains(it) }
    }

    private fun drawableToBitmap(
        drawable: Drawable?,
        tintColor: Int? = null,
        viewColorFilter: android.graphics.ColorFilter? = null
    ): Bitmap? {
        if (drawable == null) return null
        if (drawable is BitmapDrawable &&
            drawable.bitmap != null &&
            !drawable.bitmap.isRecycled &&
            tintColor == null &&
            viewColorFilter == null
        ) {
            return drawable.bitmap
        }
        return try {
            val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: 72
            val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: 72
            val bmp = Bitmap.createBitmap(w.coerceIn(1, 256), h.coerceIn(1, 256), Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            val work = drawable.mutate()
            if (viewColorFilter != null && work.colorFilter == null) {
                work.colorFilter = viewColorFilter
            } else if (tintColor != null && work.colorFilter == null) {
                work.setTint(tintColor)
            }
            work.setBounds(0, 0, canvas.width, canvas.height)
            work.draw(canvas)
            bmp
        } catch (_: Throwable) {
            null
        }
    }
}

