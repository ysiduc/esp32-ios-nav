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
        val candidateBitmaps = ArrayList<Bitmap>()

        var targetCtx: Context = this
        try {
            targetCtx = createPackageContext(GOOGLE_MAPS_PACKAGE, Context.CONTEXT_IGNORE_SECURITY)
        } catch (_: Throwable) {}

        // 1. Inflate Google Maps RemoteViews (bigContentView, contentView, headsUpContentView)
        //    to extract dynamic turn instruction rows & turn arrow ImageView bitmaps.
        val viewsToInspect = listOfNotNull(
            notification.bigContentView,
            notification.contentView,
            notification.headsUpContentView
        )
        for (rv in viewsToInspect) {
            extractFromRemoteViews(rv, targetCtx, remoteTexts, namedTexts, candidateBitmaps)
        }

        // 2. Fallback: pull Notification large icon / Icon if present
        try {
            val largeIconObj = notification.getLargeIcon()
            val d = largeIconObj?.loadDrawable(targetCtx) ?: largeIconObj?.loadDrawable(this)
            val bmp = drawableToBitmap(d)
            if (bmp != null) candidateBitmaps.add(bmp)
        } catch (_: Throwable) {}
        try {
            if (extras != null) {
                val bmp = extractBitmapExtra(extras, Notification.EXTRA_LARGE_ICON, targetCtx)
                    ?: extractBitmapExtra(extras, Notification.EXTRA_LARGE_ICON_BIG, targetCtx)
                if (bmp != null) candidateBitmaps.add(bmp)
            }
        } catch (_: Throwable) {}

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
            val classified = classifyArrowBitmap(bmp)
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
        outBitmaps: MutableList<Bitmap>
    ) {
        var inflated = false
        try {
            val container = FrameLayout(targetCtx)
            val root = rv.apply(targetCtx, container)
            if (root != null) {
                walkViewHierarchy(root, targetCtx, outTexts, outNamedTexts, outBitmaps)
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
        outBitmaps: MutableList<Bitmap>
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
                val bmp = drawableToBitmap(view.drawable)
                if (bmp != null && bmp.width in 20..512 && bmp.height in 20..512) {
                    val ratio = maxOf(bmp.width, bmp.height).toFloat() /
                        min(bmp.width, bmp.height).coerceAtLeast(1).toFloat()
                    if (ratio <= 2.1f) {
                        outBitmaps.add(bmp)
                    }
                }
            }
            is ViewGroup -> {
                for (i in 0 until view.childCount) {
                    walkViewHierarchy(view.getChildAt(i), targetCtx, outTexts, outNamedTexts, outBitmaps)
                }
            }
        }
    }

    private fun drawableToBitmap(drawable: Drawable?): Bitmap? {
        if (drawable == null) return null
        if (drawable is BitmapDrawable && drawable.bitmap != null && !drawable.bitmap.isRecycled) {
            return drawable.bitmap
        }
        return try {
            val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: 72
            val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: 72
            val bmp = Bitmap.createBitmap(w.coerceIn(1, 256), h.coerceIn(1, 256), Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            bmp
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Classifies extracted Google Maps notification turn arrow icon into ESP32 turnCode:
     * -1: unknown, 0: straight, 1: slight right, 2: turn right, 4: U-turn,
     * 6: turn left, 7: slight left, 8: roundabout.
     */
    private fun classifyArrowBitmap(src: Bitmap): Int {
        if (src.isRecycled || src.width < 16 || src.height < 16) return -1
        val size = 48
        val scaled = try {
            if (src.width == size && src.height == size) src
            else Bitmap.createScaledBitmap(src, size, size, true)
        } catch (_: Throwable) {
            return -1
        }
        val pixels = IntArray(size * size)
        scaled.getPixels(pixels, 0, size, 0, 0, size, size)

        val corners = intArrayOf(
            pixels[0],
            pixels[size - 1],
            pixels[(size - 1) * size],
            pixels[size * size - 1]
        )
        var transparentCorners = 0
        var bgR = 0
        var bgG = 0
        var bgB = 0
        for (c in corners) {
            val a = (c ushr 24) and 0xFF
            if (a < 40) transparentCorners++
            bgR += (c ushr 16) and 0xFF
            bgG += (c ushr 8) and 0xFF
            bgB += c and 0xFF
        }
        bgR /= 4
        bgG /= 4
        bgB /= 4
        val useAlphaMask = transparentCorners >= 2

        val mask = BooleanArray(size * size)
        var minX = size
        var maxX = -1
        var minY = size
        var maxY = -1
        var fgCount = 0

        for (y in 0 until size) {
            for (x in 0 until size) {
                val c = pixels[y * size + x]
                val a = (c ushr 24) and 0xFF
                val isFg = if (useAlphaMask) {
                    a >= 80
                } else {
                    val r = (c ushr 16) and 0xFF
                    val g = (c ushr 8) and 0xFF
                    val b = c and 0xFF
                    a >= 120 && (abs(r - bgR) + abs(g - bgG) + abs(b - bgB) > 55)
                }
                if (isFg) {
                    mask[y * size + x] = true
                    fgCount++
                    if (x < minX) minX = x
                    if (x > maxX) maxX = x
                    if (y < minY) minY = y
                    if (y > maxY) maxY = y
                }
            }
        }

        if (fgCount < 22 || fgCount > (size * size * 0.82)) return -1
        val boxW = maxX - minX + 1
        val boxH = maxY - minY + 1
        if (boxW < 10 || boxH < 10) return -1

        var topSumX = 0.0
        var topCnt = 0
        var midSumX = 0.0
        var midCnt = 0
        var botSumX = 0.0
        var botCnt = 0

        var coreCnt = 0
        var coreArea = 0
        var uLeftCnt = 0
        var uRightCnt = 0
        var uCenterCnt = 0
        var uAreaCenter = 0
        var topBridgeCnt = 0
        var topBridgeArea = 0

        for (y in minY..maxY) {
            val yRel = (y - minY).toDouble() / (boxH - 1).coerceAtLeast(1)
            for (x in minX..maxX) {
                val xRel = (x - minX).toDouble() / (boxW - 1).coerceAtLeast(1)
                val fg = mask[y * size + x]

                if (xRel in 0.36..0.64 && yRel in 0.36..0.64) {
                    coreArea++
                    if (fg) coreCnt++
                }
                if (yRel in 0.50..0.90) {
                    if (xRel < 0.35 && fg) uLeftCnt++
                    if (xRel > 0.65 && fg) uRightCnt++
                    if (xRel in 0.40..0.60) {
                        uAreaCenter++
                        if (fg) uCenterCnt++
                    }
                }
                if (yRel < 0.30 && xRel in 0.30..0.70) {
                    topBridgeArea++
                    if (fg) topBridgeCnt++
                }

                if (!fg) continue
                when {
                    yRel < 0.34 -> {
                        topSumX += xRel
                        topCnt++
                    }
                    yRel < 0.67 -> {
                        midSumX += xRel
                        midCnt++
                    }
                    else -> {
                        botSumX += xRel
                        botCnt++
                    }
                }
            }
        }

        if (topCnt == 0 || midCnt == 0 || botCnt == 0) return -1
        val xTop = topSumX / topCnt
        val xMid = midSumX / midCnt
        val xBot = botSumX / botCnt

        val coreFill = coreCnt.toDouble() / coreArea.coerceAtLeast(1)
        val uCenterFill = uCenterCnt.toDouble() / uAreaCenter.coerceAtLeast(1)
        val topBridgeFill = topBridgeCnt.toDouble() / topBridgeArea.coerceAtLeast(1)

        if (uLeftCnt >= 3 && uRightCnt >= 3 && uCenterFill < 0.28 && topBridgeFill > 0.22) {
            return 4 // U-turn arch
        }
        if (coreArea >= 12 && coreFill < 0.16 && topBridgeFill > 0.25 && abs(xBot - 0.5) < 0.22) {
            return 8 // Roundabout ring
        }

        val dxTop = xTop - xBot
        val dxMid = xMid - xBot
        return when {
            dxTop <= -0.18 || (dxMid <= -0.18 && xBot >= 0.46) -> 6 // Turn left
            dxTop >= 0.18 || (dxMid >= 0.18 && xBot <= 0.54) -> 2   // Turn right
            dxTop <= -0.09 -> 7                                     // Slight left
            dxTop >= 0.09 -> 1                                      // Slight right
            else -> 0                                               // Straight
        }
    }
}

