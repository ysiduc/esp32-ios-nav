package com.esp32nav.app.mobile_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.CancellationSignal
import androidx.core.location.LocationManagerCompat
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.text.TextPaint
import android.text.TextUtils
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.cos
import kotlin.math.sin

class MainActivity : FlutterActivity() {

    companion object {
        private const val REQ_PICK_ZIP = 9001
        private const val REQ_SAVE_FILE = 9002
        private const val REQ_PERMISSIONS = 9003

        @Volatile
        private var currentActivity: MainActivity? = null

        fun onNativeMediaUpdated(mediaMap: Map<String, Any>) {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.mediaChannel?.invokeMethod("onNowPlayingChanged", mediaMap)
                } catch (_: Throwable) {}
            }
        }

        fun onNativeIncomingCall(caller: String, numberOrStatus: String) {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.callChannel?.invokeMethod(
                        "onIncomingCall",
                        mapOf("caller" to caller, "number" to numberOrStatus)
                    )
                } catch (_: Throwable) {}
            }
        }

        fun onNativeCallAnswered() {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.callChannel?.invokeMethod("onCallAnswered", null)
                } catch (_: Throwable) {}
            }
        }

        fun onNativeCallEnded() {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.callChannel?.invokeMethod("onCallEnded", null)
                } catch (_: Throwable) {}
            }
        }

        fun onNativeIncomingNotification(appType: String, title: String, msg: String) {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.callChannel?.invokeMethod(
                        "onIncomingNotification",
                        mapOf("app" to appType, "title" to title, "msg" to msg)
                    )
                } catch (_: Throwable) {}
            }
        }

        fun onNativeGoogleMapsNav(data: Map<String, Any>) {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.gmapsChannel?.invokeMethod("onGoogleMapsNavigation", data)
                } catch (_: Throwable) {}
            }
        }

        fun onNativeGoogleMapsNavEnded() {
            val act = currentActivity ?: return
            act.mainHandler.post {
                try {
                    act.gmapsChannel?.invokeMethod("onGoogleMapsNavEnded", null)
                } catch (_: Throwable) {}
            }
        }
    }

    val mainHandler = Handler(Looper.getMainLooper())
    private val imageExecutor = Executors.newFixedThreadPool(2)
    private val boldSansTypeface: Typeface by lazy { Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD) }
    private val ioExecutor = Executors.newSingleThreadExecutor()

    var locationChannel: MethodChannel? = null
    var mediaChannel: MethodChannel? = null
    var callChannel: MethodChannel? = null
    var gmapsChannel: MethodChannel? = null
    var appleMapsChannel: MethodChannel? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val activeBgLockSources = HashSet<String>()

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsUsingVietnamese = false
    private var ttsHasOfflineVietnamese = false
    private var ttsHasNetworkVietnamese = false
    private var ttsEngineIndex = 0
    private var ttsCurrentEnginePkg: String? = null
    private var ttsBestEnginePkg: String? = null
    private var ttsBestEngineScore: Int = -1
    private var ttsSelectedViVoice: android.speech.tts.Voice? = null
    private var ttsProbeQueue: MutableList<String?> = mutableListOf()
    private var pendingTtsUtterance: String? = null
    private var ttsLastUtteranceText: String? = null
    private var ttsLastUtteranceRetried = false
    private var ttsRefreshScheduled = false
    private val ttsPreferredEngines = listOf<String?>("com.google.android.tts", null)
    private var audioFocusRequest: AudioFocusRequest? = null

    private var pendingZipPickResult: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private val pendingPermissionWaiters = mutableListOf<MethodChannel.Result>()
    private var isPermissionRequestInFlight = false

    private var lastReportedBattery: Int = -1
    private var lastCallState: Int = TelephonyManager.CALL_STATE_IDLE
    private var telephonyCallback: Any? = null
    @Suppress("DEPRECATION")
    private var legacyPhoneListener: PhoneStateListener? = null

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_BATTERY_CHANGED) {
                val pct = extractBatteryPercent(intent)
                if (pct in 1..100 && pct != lastReportedBattery) {
                    lastReportedBattery = pct
                    try {
                        locationChannel?.invokeMethod("onBatteryChanged", pct)
                    } catch (_: Throwable) {}
                }
            }
        }
    }

    // Fallback receiver for standard Android music player broadcasts (works even before Notification Access is enabled)
    private val musicBroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            val track = intent.getStringExtra("track")
                ?: intent.getStringExtra("title")
                ?: intent.getStringExtra("android.intent.extra.TITLE")
            val artist = intent.getStringExtra("artist")
                ?: intent.getStringExtra("albumArtist")
                ?: intent.getStringExtra("android.intent.extra.ARTIST")
            val playing = if (intent.hasExtra("playing")) {
                intent.getBooleanExtra("playing", false)
            } else if (intent.hasExtra("playstate")) {
                intent.getBooleanExtra("playstate", false)
            } else {
                true
            }
            val durationMs = intent.getLongExtra("duration", 0L)
            val positionMs = intent.getLongExtra("position", 0L)

            if (!track.isNullOrBlank() || !artist.isNullOrBlank()) {
                EspNotificationListenerService.cachedTitle = (track ?: "").trim()
                EspNotificationListenerService.cachedArtist = (artist ?: "").trim()
                EspNotificationListenerService.cachedIsPlaying = playing
                if (durationMs > 0L) {
                    EspNotificationListenerService.cachedDurationSec = (durationMs / 1000L).toInt()
                }
                if (positionMs >= 0L) {
                    EspNotificationListenerService.cachedElapsedSec = (positionMs / 1000L).toInt()
                    EspNotificationListenerService.lastPositionUpdateElapsedRealtime = SystemClock.elapsedRealtime()
                }
                onNativeMediaUpdated(EspNotificationListenerService.getCurrentMediaMap())
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        currentActivity = this
        initTextToSpeech()
        registerReceivers()
        // Note: runtime permissions are requested sequentially from Dart (BleService/NavigationManager)
        // so MainActivity, Geolocator, and FlutterBluePlus never collide with concurrent OS dialogs.
    }

    override fun onResume() {
        super.onResume()
        currentActivity = this
        EspNotificationListenerService.instance?.refreshMediaSessionsInternal(pushUpdate = true)
        // If user just returned from downloading Vietnamese TTS data or switching default engine, re-probe once.
        if (!ttsHasOfflineVietnamese) {
            mainHandler.post {
                val active = tts
                if (active != null && ttsReady) {
                    val refreshed = scoreAndConfigureVietnameseTts(active)
                    if (refreshed >= 3) {
                        ttsUsingVietnamese = true
                        ttsHasOfflineVietnamese = true
                        ttsHasNetworkVietnamese = false
                    } else if (!ttsUsingVietnamese) {
                        initTextToSpeech(0)
                    }
                } else if (!ttsRefreshScheduled) {
                    initTextToSpeech(0)
                }
            }
        }
    }

    override fun onDestroy() {
        stopBackgroundLocks("all")
        unregisterReceivers()
        unregisterTelephonyListener()
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Throwable) {}
        if (currentActivity === this) {
            currentActivity = null
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 1. Location, TTS, Battery, Background WakeLock, Native JPEG HUD Renderer & File Picker Channel
        locationChannel = MethodChannel(messenger, "com.ysiduc.esp32_nav/location")
        locationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startBackgroundNavigation" -> {
                    val args = call.arguments as? Map<*, *>
                    val source = (args?.get("source") as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: "default"
                    startBackgroundLocks(source)
                    result.success(true)
                }
                "stopBackgroundNavigation" -> {
                    val args = call.arguments as? Map<*, *>
                    val source = (args?.get("source") as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: "default"
                    stopBackgroundLocks(source)
                    result.success(true)
                }
                "speakGuidance" -> {
                    val args = call.arguments as? Map<*, *>
                    val text = (args?.get("text") as? String)?.trim() ?: ""
                    if (text.isNotEmpty()) {
                        result.success(speakVietnameseGuidance(text))
                    } else {
                        result.success(mapOf("ok" to false, "empty" to true))
                    }
                }
                "stopGuidance" -> {
                    try {
                        tts?.stop()
                        abandonAudioFocus()
                    } catch (_: Throwable) {}
                    result.success(true)
                }
                "getTtsStatus" -> {
                    val active = tts
                    if (active != null && ttsReady && !ttsHasOfflineVietnamese) {
                        val refreshed = scoreAndConfigureVietnameseTts(active)
                        ttsUsingVietnamese = refreshed >= 1
                        ttsHasOfflineVietnamese = refreshed >= 3
                        ttsHasNetworkVietnamese = refreshed == 2
                    }
                    result.success(
                        mapOf(
                            "ready" to ttsReady,
                            "usingVietnamese" to ttsUsingVietnamese,
                            "hasOfflineVietnamese" to ttsHasOfflineVietnamese,
                            "hasNetworkVietnamese" to ttsHasNetworkVietnamese,
                            "engine" to (ttsCurrentEnginePkg ?: ""),
                            "voiceLocale" to (tts?.voice?.locale?.toLanguageTag() ?: ""),
                            "voiceName" to (tts?.voice?.name ?: ""),
                            "diagnostic" to buildTtsDiagnosticString(active)
                        )
                    )
                }
                "installVietnameseTtsData" -> {
                    result.success(launchInstallVietnameseTtsData())
                }
                "openTtsSettings" -> {
                    result.success(launchSystemTtsSettings())
                }
                "getBatteryLevel" -> {
                    result.success(readPhoneBatteryPercent())
                }
                "shareLog" -> {
                    val args = call.arguments as? Map<*, *>
                    val text = args?.get("text") as? String ?: ""
                    val fileName = args?.get("fileName") as? String ?: "esp32_tx_rx_log.txt"
                    if (text.isEmpty()) {
                        result.success(false)
                    } else {
                        shareTextContent(text, fileName)
                        result.success(true)
                    }
                }
                "shareFileBytes" -> {
                    val args = call.arguments as? Map<*, *>
                    val bytes = args?.get("bytes") as? ByteArray
                    val fileName = args?.get("fileName") as? String ?: "esp32_theme.zip"
                    if (bytes == null || bytes.isEmpty()) {
                        result.success(false)
                    } else {
                        saveOrShareBinaryFile(bytes, fileName, result)
                    }
                }
                "pickZipFile" -> {
                    launchZipFilePicker(result)
                }
                "compressRgbaToJpeg" -> {
                    val args = call.arguments as? Map<*, *>
                    val rgba = args?.get("rgba") as? ByteArray
                    val width = (args?.get("width") as? Number)?.toInt() ?: 0
                    val height = (args?.get("height") as? Number)?.toInt() ?: 0
                    val rawQuality = (args?.get("quality") as? Number)?.toDouble() ?: 0.85
                    val quality = if (rawQuality <= 1.0) {
                        (rawQuality * 100.0).toInt().coerceIn(10, 100)
                    } else {
                        rawQuality.toInt().coerceIn(10, 100)
                    }
                    val isDark = (args?.get("isDark") as? Boolean) ?: false
                    @Suppress("UNCHECKED_CAST")
                    val roadLabels = args?.get("roadLabels") as? List<Map<String, Any>>
                    @Suppress("UNCHECKED_CAST")
                    val hud = args?.get("hud") as? Map<String, Any>

                    if (rgba == null || width <= 0 || height <= 0 || rgba.size < width * height * 4) {
                        result.error("INVALID_ARGS", "Invalid RGBA buffer or dimensions", null)
                    } else {
                        imageExecutor.execute {
                            try {
                                val jpegBytes = renderAndCompressRgbaToJpeg(
                                    rgba = rgba,
                                    width = width,
                                    height = height,
                                    quality = quality,
                                    isDark = isDark,
                                    roadLabels = roadLabels,
                                    hud = hud
                                )
                                mainHandler.post { result.success(jpegBytes) }
                            } catch (t: Throwable) {
                                mainHandler.post {
                                    result.error("ENCODE_FAILED", t.message ?: "Failed to encode JPEG", null)
                                }
                            }
                        }
                    }
                }
                "isNotificationListenerEnabled" -> {
                    result.success(isNotificationServiceEnabled())
                }
                "openNotificationListenerSettings" -> {
                    openNotificationAccessSettings()
                    result.success(true)
                }
                "requestAndroidPermissions" -> {
                    val args = call.arguments as? Map<*, *>
                    val mode = (args?.get("mode") as? String)?.trim()?.lowercase() ?: "all"
                    requestEssentialRuntimePermissions(mode = mode, result = result)
                }
                "getAndroidPermissionStatus" -> {
                    result.success(buildPermissionSummaryMap())
                }
                "openLocationSettings" -> {
                    openLocationSettingsScreen()
                    result.success(true)
                }
                "openAppSettings" -> {
                    openAppDetailsSettingsScreen()
                    result.success(true)
                }
                "getNativeCurrentLocation" -> {
                    getNativeCurrentLocation(result)
                }
                "openWifiApTcpRelay" -> {
                    val args = call.arguments as? Map<*, *>
                    val host = (args?.get("host") as? String)?.trim() ?: "192.168.4.1"
                    val port = (args?.get("port") as? Number)?.toInt() ?: 8081
                    ioExecutor.execute {
                        val relayPort = openWifiApTcpRelay(host, port)
                        mainHandler.post { result.success(relayPort) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 2. Now Playing Media Channel (Android MediaSessionManager + Music Broadcasts)
        mediaChannel = MethodChannel(messenger, "com.ysiduc.esp32_nav/media")
        mediaChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getNowPlaying" -> {
                    result.success(EspNotificationListenerService.getCurrentMediaMap())
                }
                else -> result.notImplemented()
            }
        }

        // 3. Phone Calls & System Notifications Channel (TelephonyManager + NotificationListenerService)
        callChannel = MethodChannel(messenger, "com.ysiduc.esp32_nav/calls")
        callChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationListenerEnabled" -> result.success(isNotificationServiceEnabled())
                "openNotificationListenerSettings" -> {
                    openNotificationAccessSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        setupTelephonyListener()

        // 3b. Dedicated Google Maps Notification Navigation Channel (maisonsmd/esp32-google-maps style)
        gmapsChannel = MethodChannel(messenger, "com.ysiduc.esp32_nav/gmaps")
        gmapsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationListenerEnabled" -> result.success(isNotificationServiceEnabled())
                "openNotificationListenerSettings" -> {
                    openNotificationAccessSettings()
                    result.success(true)
                }
                "scanGoogleMapsNotification" -> {
                    result.success(EspNotificationListenerService.rescanGoogleMapsNotification())
                }
                "launchGoogleMaps" -> {
                    val launched = try {
                        val launchIntent = packageManager.getLaunchIntentForPackage(
                            EspNotificationListenerService.GOOGLE_MAPS_PACKAGE
                        )
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launchIntent)
                            true
                        } else {
                            false
                        }
                    } catch (_: Throwable) {
                        false
                    }
                    result.success(launched)
                }
                else -> result.notImplemented()
            }
        }

        // 4. Native Geocoding & Place Lookup Channel
        appleMapsChannel = MethodChannel(messenger, "com.ysiduc.esp32_nav/apple_maps")
        appleMapsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "reverseGeocodeStreet" -> {
                    val args = call.arguments as? Map<*, *>
                    val lat = (args?.get("lat") as? Number)?.toDouble()
                    val lon = ((args?.get("lng") as? Number) ?: (args?.get("lon") as? Number))?.toDouble()
                    if (lat == null || lon == null) {
                        result.success(null)
                    } else {
                        ioExecutor.execute {
                            val street = reverseGeocodeStreetNative(lat, lon)
                            mainHandler.post { result.success(street) }
                        }
                    }
                }
                "searchPlaces", "searchAutocomplete" -> {
                    // Return empty list so Dart uses Goong / Photon / Nominatim on Android
                    result.success(emptyList<Map<String, Any>>())
                }
                "getRoute" -> {
                    // Return null so Dart uses Goong / OSRM on Android
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // =========================================================================
    // RUNTIME PERMISSIONS, LOCATION FALLBACK & NOTIFICATION ACCESS HELPERS
    // =========================================================================
    private fun hasAnyLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            val bt = ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED
            val admin = ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED
            bt && admin && hasAnyLocationPermission()
        }
    }

    private fun isLocationEnabledNative(): Boolean {
        return try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
            LocationManagerCompat.isLocationEnabled(lm)
        } catch (_: Throwable) {
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun isBluetoothEnabledNative(): Boolean {
        return try {
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bm?.adapter?.isEnabled == true
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildPermissionSummaryMap(): Map<String, Any> {
        val fineGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "locationGranted" to hasAnyLocationPermission(),
            "fineLocationGranted" to fineGranted,
            "bleGranted" to hasBlePermissions(),
            "locationServiceEnabled" to isLocationEnabledNative(),
            "bluetoothEnabled" to isBluetoothEnabledNative(),
            "sdkInt" to Build.VERSION.SDK_INT
        )
    }

    private fun requestEssentialRuntimePermissions(mode: String = "all", result: MethodChannel.Result) {
        val needed = mutableListOf<String>()
        val includeBle = mode == "all" || mode == "ble"
        val includeLocation = mode == "all" || mode == "location" || (includeBle && Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
        val includeAux = mode == "all"

        if (includeBle && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.BLUETOOTH_SCAN)
            }
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }
        if (includeLocation) {
            val fineMissing = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
            val coarseMissing = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED
            if (fineMissing) {
                needed.add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            if (coarseMissing || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && fineMissing)) {
                if (!needed.contains(Manifest.permission.ACCESS_COARSE_LOCATION)) {
                    needed.add(Manifest.permission.ACCESS_COARSE_LOCATION)
                }
            }
        }
        if (includeAux) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    needed.add(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.READ_PHONE_STATE)
            }
        }

        if (needed.isEmpty()) {
            setupTelephonyListener()
            result.success(buildPermissionSummaryMap())
            return
        }

        pendingPermissionWaiters.add(result)
        if (!isPermissionRequestInFlight) {
            isPermissionRequestInFlight = true
            try {
                ActivityCompat.requestPermissions(this, needed.distinct().toTypedArray(), REQ_PERMISSIONS)
            } catch (_: Throwable) {
                isPermissionRequestInFlight = false
                val waiters = ArrayList(pendingPermissionWaiters)
                pendingPermissionWaiters.clear()
                val summary = buildPermissionSummaryMap()
                for (w in waiters) {
                    try { w.success(summary) } catch (_: Throwable) {}
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_PERMISSIONS) {
            isPermissionRequestInFlight = false
            setupTelephonyListener()
            val summary = buildPermissionSummaryMap()
            val waiters = ArrayList(pendingPermissionWaiters)
            pendingPermissionWaiters.clear()
            for (w in waiters) {
                try {
                    w.success(summary)
                } catch (_: Throwable) {}
            }
        }
    }

    private fun openLocationSettingsScreen() {
        try {
            val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Throwable) {
            try {
                val fallback = Intent(Settings.ACTION_SETTINGS)
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallback)
            } catch (_: Throwable) {}
        }
    }

    private fun openAppDetailsSettingsScreen() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Throwable) {}
    }

    private fun locationToMap(loc: Location): Map<String, Any> {
        return mapOf(
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "accuracy" to (if (loc.hasAccuracy()) loc.accuracy.toDouble() else 35.0),
            "speed" to (if (loc.hasSpeed()) loc.speed.toDouble() else 0.0),
            "bearing" to (if (loc.hasBearing()) loc.bearing.toDouble() else -1.0),
            "timestampMs" to loc.time
        )
    }

    @SuppressLint("MissingPermission")
    private fun getNativeCurrentLocation(result: MethodChannel.Result) {
        if (!hasAnyLocationPermission()) {
            result.success(null)
            return
        }
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            result.success(null)
            return
        }

        val candidates = mutableListOf<Location>()
        val probeProviders = mutableListOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            probeProviders.add(0, LocationManager.FUSED_PROVIDER)
        }
        for (provider in probeProviders.distinct()) {
            try {
                lm.getLastKnownLocation(provider)?.let { candidates.add(it) }
            } catch (_: Throwable) {}
        }

        val bestLast = candidates
            .filter { it.latitude != 0.0 || it.longitude != 0.0 }
            .maxWithOrNull(
                compareBy<Location> { it.time / 2500L }
                    .thenBy { if (it.hasSpeed() && it.speed > 0f) 1 else 0 }
                    .thenBy { -it.accuracy }
            )

        val nowMs = System.currentTimeMillis()
        if (bestLast != null && (nowMs - bestLast.time) <= 20_000L && bestLast.accuracy in 0.1f..45f) {
            result.success(locationToMap(bestLast))
            return
        }

        val activeProviders = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                if (lm.isProviderEnabled(LocationManager.FUSED_PROVIDER)) {
                    activeProviders.add(LocationManager.FUSED_PROVIDER)
                }
            } catch (_: Throwable) {}
        }
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            try {
                if (lm.isProviderEnabled(p)) activeProviders.add(p)
            } catch (_: Throwable) {}
        }

        if (activeProviders.isEmpty()) {
            result.success(bestLast?.let { locationToMap(it) })
            return
        }

        var settled = false
        val cancelSignals = mutableListOf<CancellationSignal>()
        val legacyListeners = mutableListOf<LocationListener>()

        fun cleanupListeners() {
            for (sig in cancelSignals) {
                try { sig.cancel() } catch (_: Throwable) {}
            }
            cancelSignals.clear()
            for (listener in legacyListeners) {
                try { lm.removeUpdates(listener) } catch (_: Throwable) {}
            }
            legacyListeners.clear()
        }

        fun finishWith(loc: Location?) {
            if (settled) return
            settled = true
            cleanupListeners()
            val chosen = loc ?: bestLast
            mainHandler.post {
                try {
                    result.success(chosen?.let { locationToMap(it) })
                } catch (_: Throwable) {}
            }
        }

        mainHandler.postDelayed({
            finishWith(bestLast)
        }, 4500L)

        for (provider in activeProviders) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val signal = CancellationSignal()
                    cancelSignals.add(signal)
                    lm.getCurrentLocation(
                        provider,
                        signal,
                        mainExecutor
                    ) { loc ->
                        if (loc != null && (loc.latitude != 0.0 || loc.longitude != 0.0)) {
                            finishWith(loc)
                        }
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val listener = object : LocationListener {
                        override fun onLocationChanged(loc: Location) {
                            if (loc.latitude != 0.0 || loc.longitude != 0.0) {
                                finishWith(loc)
                            }
                        }
                        @Deprecated("Deprecated in Java")
                        override fun onStatusChanged(p: String?, status: Int, extras: Bundle?) {}
                        override fun onProviderEnabled(p: String) {}
                        override fun onProviderDisabled(p: String) {}
                    }
                    legacyListeners.add(listener)
                    @Suppress("DEPRECATION")
                    lm.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                }
            } catch (_: Throwable) {}
        }
    }

    private fun isNotificationServiceEnabled(): Boolean {
        return try {
            val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
            flat.contains(packageName)
        } catch (_: Throwable) {
            false
        }
    }

    private fun openNotificationAccessSettings() {
        try {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Throwable) {
            try {
                val fallback = Intent(Settings.ACTION_SETTINGS)
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallback)
            } catch (_: Throwable) {}
        }
    }

    // =========================================================================
    // BATTERY & MUSIC BROADCAST RECEIVERS
    // =========================================================================
    private fun registerReceivers() {
        try {
            registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (_: Throwable) {}

        try {
            val musicFilter = IntentFilter().apply {
                addAction("com.android.music.metachanged")
                addAction("com.android.music.playstatechanged")
                addAction("com.spotify.music.metadatachanged")
                addAction("com.spotify.music.playbackstatechanged")
                addAction("com.htc.music.metachanged")
                addAction("com.sec.android.app.music.metachanged")
                addAction("com.miui.player.metachanged")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(musicBroadcastReceiver, musicFilter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(musicBroadcastReceiver, musicFilter)
            }
        } catch (_: Throwable) {}
    }

    private fun unregisterReceivers() {
        try {
            unregisterReceiver(batteryReceiver)
        } catch (_: Throwable) {}
        try {
            unregisterReceiver(musicBroadcastReceiver)
        } catch (_: Throwable) {}
    }

    private fun readPhoneBatteryPercent(): Int {
        try {
            val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            val cap = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            if (cap in 1..100) return cap
        } catch (_: Throwable) {}
        try {
            val sticky = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val pct = extractBatteryPercent(sticky)
            if (pct in 1..100) return pct
        } catch (_: Throwable) {}
        return 100
    }

    private fun extractBatteryPercent(intent: Intent?): Int {
        if (intent == null) return -1
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level >= 0 && scale > 0) {
            return ((level * 100f) / scale.toFloat()).toInt().coerceIn(1, 100)
        }
        return -1
    }

    // =========================================================================
    // TELEPHONY CALL STATE LISTENER
    // =========================================================================
    private fun setupTelephonyListener() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return
            unregisterTelephonyListener()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        handleTelephonyCallState(state, null)
                    }
                }
                tm.registerTelephonyCallback(mainExecutor, cb)
                telephonyCallback = cb
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        handleTelephonyCallState(state, phoneNumber)
                    }
                }
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                legacyPhoneListener = listener
            }
        } catch (_: Throwable) {}
    }

    private fun unregisterTelephonyListener() {
        try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = telephonyCallback as? TelephonyCallback
                if (cb != null) tm.unregisterTelephonyCallback(cb)
                telephonyCallback = null
            } else {
                @Suppress("DEPRECATION")
                val listener = legacyPhoneListener
                if (listener != null) {
                    @Suppress("DEPRECATION")
                    tm.listen(listener, PhoneStateListener.LISTEN_NONE)
                }
                legacyPhoneListener = null
            }
        } catch (_: Throwable) {}
    }

    private fun handleTelephonyCallState(state: Int, incomingNumber: String?) {
        if (state == lastCallState) return
        lastCallState = state
        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                val num = if (!incomingNumber.isNullOrBlank()) incomingNumber else "Đang đổ chuông..."
                onNativeIncomingCall("Cuộc gọi đến", num)
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                onNativeCallAnswered()
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                onNativeCallEnded()
            }
        }
    }

    // =========================================================================
    // BACKGROUND WAKELOCK & WIFILOCK FOR SCREEN-OFF ESP32 STREAMING
    // =========================================================================
    @Suppress("DEPRECATION")
    private fun startBackgroundLocks(source: String = "default") {
        activeBgLockSources.add(source)
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "esp32nav:NavWakeLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire(6 * 60 * 60 * 1000L) // up to 6 hours
            }
        } catch (_: Throwable) {}

        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                val lockMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm?.createWifiLock(lockMode, "esp32nav:NavWifiLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (wifiLock?.isHeld == false) {
                wifiLock?.acquire()
            }
        } catch (_: Throwable) {}

        NavForegroundService.start(applicationContext)
    }

    private fun stopBackgroundLocks(source: String = "default") {
        if (source == "all") {
            activeBgLockSources.clear()
        } else {
            activeBgLockSources.remove(source)
            if (activeBgLockSources.isNotEmpty()) {
                return
            }
        }
        NavForegroundService.stop(applicationContext)
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Throwable) {}
        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: Throwable) {}
    }

    // =========================================================================
    // VIETNAMESE TEXT-TO-SPEECH VOICE GUIDANCE
    // =========================================================================
    private fun isVietnameseLocale(locale: Locale?): Boolean {
        if (locale == null) return false
        val lang = locale.language.lowercase(Locale.ROOT)
        if (lang == "vi" || lang == "vie") return true
        val tag = try {
            locale.toLanguageTag().lowercase(Locale.ROOT)
        } catch (_: Throwable) {
            locale.toString().lowercase(Locale.ROOT)
        }
        return tag == "vi" ||
            tag == "vie" ||
            tag.startsWith("vi-") ||
            tag.startsWith("vi_") ||
            tag.startsWith("vie-")
    }

    private fun scoreAndConfigureVietnameseTts(engine: TextToSpeech?, preferOfflineOnly: Boolean = false): Int {
        if (engine == null) return 0
        if (engine === tts) {
            ttsSelectedViVoice = null
        }
        val defaultViLocale = Locale.forLanguageTag("vi-VN")

        val voices = try {
            engine.voices
        } catch (_: Throwable) {
            null
        }
        val installedViVoices = voices
            ?.filter { v ->
                isVietnameseLocale(v.locale) &&
                    v.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true &&
                    !v.name.contains("not_installed", ignoreCase = true) &&
                    (!preferOfflineOnly || (!v.isNetworkConnectionRequired && !v.name.contains("network", ignoreCase = true)))
            }
            ?.sortedWith(
                compareBy<android.speech.tts.Voice> {
                    if (it.isNetworkConnectionRequired || it.name.contains("network", ignoreCase = true)) 1 else 0
                }.thenBy {
                    if (it.locale?.country.equals("VN", ignoreCase = true)) 0 else 1
                }
            )

        // First pick an actually installed Vietnamese voice and apply language BEFORE explicit voice,
        // because AOSP TextToSpeech.setLanguage resets explicit voice selection.
        for (candidateVoice in installedViVoices.orEmpty()) {
            val isNetworkOnly = candidateVoice.isNetworkConnectionRequired ||
                candidateVoice.name.contains("network", ignoreCase = true)
            val voiceLocale = candidateVoice.locale ?: defaultViLocale
            try {
                engine.language = voiceLocale
            } catch (_: Throwable) {}
            try {
                val res = engine.setVoice(candidateVoice)
                val activeVoice = engine.voice
                if (res == TextToSpeech.SUCCESS &&
                    (activeVoice == null || isVietnameseLocale(activeVoice.locale))) {
                    if (engine === tts) {
                        ttsSelectedViVoice = candidateVoice
                    }
                    return if (!isNetworkOnly) 3 else 2
                }
            } catch (_: Throwable) {}
        }

        // If engine.voices is populated and none of the installed voices are Vietnamese,
        // do NOT trust isLanguageAvailable() — Android often returns LANG_AVAILABLE for
        // unloaded/English fallback engines and would pronounce Vietnamese as foreign gibberish.
        if (!voices.isNullOrEmpty()) {
            return 0
        }

        val candidates = listOf(defaultViLocale, Locale("vi")).distinct()
        for (loc in candidates) {
            try {
                val avail = engine.isLanguageAvailable(loc)
                if (avail >= TextToSpeech.LANG_AVAILABLE) {
                    val res = engine.setLanguage(loc)
                    if (res >= TextToSpeech.LANG_AVAILABLE) {
                        val activeVoiceLocale = engine.voice?.locale
                        if (activeVoiceLocale == null || isVietnameseLocale(activeVoiceLocale)) {
                            return 1
                        }
                    }
                }
            } catch (_: Throwable) {}
        }
        return 0
    }

    private var ttsGoogleInitSucceeded = false

    private fun buildTtsDiagnosticString(engine: TextToSpeech?): String {
        val pkg = ttsCurrentEnginePkg?.ifEmpty { null } ?: engine?.defaultEngine ?: "none"
        val voice = try { engine?.voice } catch (_: Throwable) { null }
        val availVi = try { engine?.isLanguageAvailable(Locale.forLanguageTag("vi-VN")) } catch (_: Throwable) { -99 }
        val viSummary = try {
            engine?.voices
                ?.filter { isVietnameseLocale(it.locale) }
                ?.joinToString(",") { v ->
                    val notInst = v.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) == true
                    val net = v.isNetworkConnectionRequired
                    "${v.name}[${if (notInst) "missing" else if (net) "net" else "local"}]"
                } ?: ""
        } catch (_: Throwable) { "" }
        val enginesList = try {
            engine?.engines?.joinToString(",") { it.name } ?: ""
        } catch (_: Throwable) { "" }
        return "pkg=$pkg, availVi=$availVi, active=${voice?.name ?: "-"}(${voice?.locale?.toLanguageTag() ?: "-"}), vi=[$viSummary], all=[$enginesList]"
    }

    private fun initTextToSpeech(engineAttemptIndex: Int = 0) {
        try {
            if (engineAttemptIndex == 0) {
                ttsBestEnginePkg = null
                ttsBestEngineScore = -1
                ttsGoogleInitSucceeded = false
                ttsProbeQueue = ttsPreferredEngines.toMutableList()
            }
            ttsEngineIndex = engineAttemptIndex
            ttsReady = false
            ttsUsingVietnamese = false
            ttsHasOfflineVietnamese = false
            ttsHasNetworkVietnamese = false
            try {
                tts?.shutdown()
            } catch (_: Throwable) {}

            val enginePkg = ttsProbeQueue.getOrNull(engineAttemptIndex)
            lateinit var listener: TextToSpeech.OnInitListener
            listener = TextToSpeech.OnInitListener { status ->
                val currentTts = tts
                if (status == TextToSpeech.SUCCESS && currentTts != null) {
                    if (enginePkg == "com.google.android.tts") {
                        ttsGoogleInitSucceeded = true
                    }
                    if (engineAttemptIndex == 0) {
                        val installed = try {
                            currentTts.engines?.mapNotNull { it.name } ?: emptyList()
                        } catch (_: Throwable) {
                            emptyList()
                        }
                        for (pkg in installed) {
                            if (!ttsProbeQueue.contains(pkg)) {
                                ttsProbeQueue.add(pkg)
                            }
                        }
                    }

                    fun evaluateCurrentEngine(allowWaitRetry: Boolean) {
                        val activeTts = tts
                        if (activeTts == null || activeTts !== currentTts) return
                        val score = scoreAndConfigureVietnameseTts(activeTts)
                        val voicesEmpty = try { activeTts.voices.isNullOrEmpty() } catch (_: Throwable) { true }
                        // Google TTS hydrates voices asynchronously right after onInit(SUCCESS):
                        // wait briefly before tearing it down so we don't reject a valid engine prematurely.
                        if (allowWaitRetry && score < 2 && (voicesEmpty || enginePkg == "com.google.android.tts")) {
                            mainHandler.postDelayed({ evaluateCurrentEngine(allowWaitRetry = false) }, 350L)
                            return
                        }

                        val candidatePkg = enginePkg ?: activeTts.defaultEngine
                        if (score > ttsBestEngineScore) {
                            ttsBestEngineScore = score
                            ttsBestEnginePkg = candidatePkg
                        }

                        if (score >= 3) {
                            ttsCurrentEnginePkg = candidatePkg
                            ttsUsingVietnamese = true
                            ttsHasOfflineVietnamese = true
                            ttsHasNetworkVietnamese = false
                            finalizeTtsSetup()
                            return
                        }

                        if (engineAttemptIndex + 1 < ttsProbeQueue.size) {
                            mainHandler.post { initTextToSpeech(engineAttemptIndex + 1) }
                            return
                        }

                        val winningPkg = ttsBestEnginePkg
                        if (ttsBestEngineScore >= 1 && winningPkg != null && winningPkg != enginePkg) {
                            mainHandler.post { lockBestVietnameseEngine(winningPkg) }
                            return
                        }

                        // If no engine had vi-VN installed at probe time, still lock Google TTS over OEM English-only engines
                        if (ttsBestEngineScore <= 0 && ttsGoogleInitSucceeded && enginePkg != "com.google.android.tts") {
                            mainHandler.post { lockBestVietnameseEngine("com.google.android.tts") }
                            return
                        }

                        ttsCurrentEnginePkg = candidatePkg
                        ttsUsingVietnamese = score >= 1
                        ttsHasOfflineVietnamese = score >= 3
                        ttsHasNetworkVietnamese = score == 2
                        finalizeTtsSetup()
                    }

                    evaluateCurrentEngine(allowWaitRetry = true)
                } else if (engineAttemptIndex + 1 < ttsProbeQueue.size) {
                    mainHandler.post { initTextToSpeech(engineAttemptIndex + 1) }
                } else if (ttsBestEngineScore >= 1 && ttsBestEnginePkg != null) {
                    mainHandler.post { lockBestVietnameseEngine(ttsBestEnginePkg!!) }
                } else if (ttsGoogleInitSucceeded) {
                    mainHandler.post { lockBestVietnameseEngine("com.google.android.tts") }
                } else {
                    ttsCurrentEnginePkg = enginePkg ?: ""
                    ttsUsingVietnamese = false
                    ttsHasOfflineVietnamese = false
                    ttsHasNetworkVietnamese = false
                    ttsReady = false
                }
            }

            tts = if (enginePkg != null) {
                TextToSpeech(applicationContext, listener, enginePkg)
            } else {
                TextToSpeech(applicationContext, listener)
            }
        } catch (_: Throwable) {}
    }

    private fun lockBestVietnameseEngine(enginePkg: String) {
        try {
            try {
                tts?.shutdown()
            } catch (_: Throwable) {}
            lateinit var lockedInstance: TextToSpeech
            lockedInstance = TextToSpeech(applicationContext, { status ->
                if (status == TextToSpeech.SUCCESS) {
                    mainHandler.postDelayed({
                        val active = tts
                        if (active == null || active !== lockedInstance) return@postDelayed
                        val score = scoreAndConfigureVietnameseTts(active)
                        ttsCurrentEnginePkg = enginePkg
                        ttsUsingVietnamese = score >= 1
                        ttsHasOfflineVietnamese = score >= 3
                        ttsHasNetworkVietnamese = score == 2
                        finalizeTtsSetup()
                    }, 220L)
                }
            }, enginePkg)
            tts = lockedInstance
        } catch (_: Throwable) {}
    }

    private fun launchSystemTtsSettings(): Boolean {
        val candidates = listOf(
            Intent("com.android.settings.TTS_SETTINGS").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
        for (intent in candidates) {
            try {
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Throwable) {}
        }
        return false
    }

    private fun launchInstallVietnameseTtsData(): Boolean {
        val candidates = listOf(
            Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                setPackage("com.google.android.tts")
            },
            Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            Intent("com.android.settings.TTS_SETTINGS").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.tts")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
        for (intent in candidates) {
            try {
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Throwable) {}
        }
        return false
    }

    private fun refreshActiveTtsVoiceAsync(delayMs: Long) {
        ttsRefreshScheduled = true
        mainHandler.postDelayed({
            ttsRefreshScheduled = false
            val active = tts ?: return@postDelayed
            if (!ttsReady) return@postDelayed
            val score = scoreAndConfigureVietnameseTts(active)
            if (score > 0 && (!ttsUsingVietnamese || score >= 3 && !ttsHasOfflineVietnamese)) {
                ttsUsingVietnamese = true
                ttsHasOfflineVietnamese = score >= 3
                ttsHasNetworkVietnamese = score == 2
            }
        }, delayMs)
    }

    private fun finalizeTtsSetup() {
        ttsReady = true
        tts?.setSpeechRate(1.02f)
        tts?.setPitch(1.0f)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                tts?.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
            } catch (_: Throwable) {}
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                abandonAudioFocus()
            }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                val retryText = ttsLastUtteranceText
                if (!ttsLastUtteranceRetried && !retryText.isNullOrBlank()) {
                    ttsLastUtteranceRetried = true
                    mainHandler.post {
                        val active = tts
                        if (active != null && scoreAndConfigureVietnameseTts(active, preferOfflineOnly = true) >= 1) {
                            speakVietnameseGuidance(retryText, isRetry = true)
                            return@post
                        }
                        abandonAudioFocus()
                    }
                    return
                }
                abandonAudioFocus()
            }
        })
        // Google TTS loads voices asynchronously shortly after onInit(SUCCESS)
        if (!ttsHasOfflineVietnamese) {
            refreshActiveTtsVoiceAsync(400L)
            refreshActiveTtsVoiceAsync(1300L)
        }
        val pending = pendingTtsUtterance
        pendingTtsUtterance = null
        if (!pending.isNullOrBlank()) {
            speakVietnameseGuidance(pending)
        }
    }

    private fun speakVietnameseGuidance(text: String, isRetry: Boolean = false): Map<String, Any> {
        val activeTts = tts
        if (!ttsReady || activeTts == null) {
            pendingTtsUtterance = text
            return mapOf("ok" to true, "queued" to true)
        }
        try {
            val lockedVoice = ttsSelectedViVoice
            if (lockedVoice != null && activeTts.voice?.name != lockedVoice.name) {
                try {
                    activeTts.voice = lockedVoice
                } catch (_: Throwable) {}
            }
            val currentVoiceLocale = activeTts.voice?.locale
            if (!ttsUsingVietnamese || (currentVoiceLocale != null && !isVietnameseLocale(currentVoiceLocale))) {
                val score = scoreAndConfigureVietnameseTts(activeTts)
                ttsUsingVietnamese = score >= 1
                ttsHasOfflineVietnamese = score >= 3
                ttsHasNetworkVietnamese = score == 2
            }
            // Never allow non-Vietnamese (English/Chinese/OEM) TTS engines to mispronounce Vietnamese text.
            if (!ttsUsingVietnamese) {
                abandonAudioFocus()
                return mapOf(
                    "ok" to false,
                    "missingVietnamese" to true,
                    "usingVietnamese" to false,
                    "engine" to (ttsCurrentEnginePkg ?: activeTts.defaultEngine ?: ""),
                    "diagnostic" to buildTtsDiagnosticString(activeTts)
                )
            }
            if (!isRetry) {
                ttsLastUtteranceText = text
                ttsLastUtteranceRetried = false
            }
            requestDuckingAudioFocus()
            val params = Bundle().apply {
                putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
                if (activeTts.voice?.isNetworkConnectionRequired == true) {
                    putString(TextToSpeech.Engine.KEY_FEATURE_NETWORK_SYNTHESIS, "true")
                }
            }
            val rc = activeTts.speak(
                text,
                TextToSpeech.QUEUE_FLUSH,
                params,
                "esp32_nav_tts_${System.currentTimeMillis()}"
            )
            if (rc == TextToSpeech.ERROR) {
                abandonAudioFocus()
                return mapOf("ok" to false, "error" to "speak_error")
            }
            return mapOf("ok" to true, "usingVietnamese" to true)
        } catch (t: Throwable) {
            return mapOf("ok" to false, "error" to (t.message ?: "exception"))
        }
    }

    private fun requestDuckingAudioFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(attrs)
                    .build()
                audioFocusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    null,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                )
            }
        } catch (_: Throwable) {}
    }

    private fun abandonAudioFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (_: Throwable) {}
    }

    // =========================================================================
    // NATIVE ANDROID GEOCODER FOR VIETNAMESE STREET NAMES
    // =========================================================================
    private fun isAdministrativeOrCityName(raw: String): Boolean {
        val lower = raw.trim().lowercase()
        if (lower.isEmpty()) return true
        if (lower.matches(Regex("^\\d+$")) || lower.contains("+")) return true
        val cityTokens = setOf(
            "hà nội", "ha noi", "hanoi", "thành phố hà nội", "tp hà nội", "tp. hà nội",
            "hồ chí minh", "ho chi minh", "tp hcm", "tp.hcm", "sài gòn", "sai gon",
            "đà nẵng", "da nang", "hải phòng", "hai phong", "cần thơ", "can tho",
            "việt nam", "vietnam", "viet nam"
        )
        if (lower in cityTokens) return true
        return lower.startsWith("quận ") ||
            lower.startsWith("quan ") ||
            lower.startsWith("phường ") ||
            lower.startsWith("phuong ") ||
            lower.startsWith("huyện ") ||
            lower.startsWith("huyen ") ||
            lower.startsWith("thị xã ") ||
            lower.startsWith("thị trấn ") ||
            lower.startsWith("xã ") ||
            lower.startsWith("thành phố ") ||
            lower.startsWith("tp ") ||
            lower.startsWith("tp.") ||
            lower.startsWith("tỉnh ")
    }

    private fun reverseGeocodeStreetNative(lat: Double, lon: Double): String? {
        if (!Geocoder.isPresent()) return null
        return try {
            val geocoder = Geocoder(this, Locale("vi", "VN"))
            @Suppress("DEPRECATION")
            val list = geocoder.getFromLocation(lat, lon, 3)
            if (list.isNullOrEmpty()) return null
            for (addr in list) {
                val thoroughfare = addr.thoroughfare?.trim()
                if (!thoroughfare.isNullOrEmpty() && !isAdministrativeOrCityName(thoroughfare)) {
                    return thoroughfare
                }
            }
            val firstLine = list[0].getAddressLine(0) ?: return null
            val parts = firstLine.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            for (part in parts) {
                if (!isAdministrativeOrCityName(part)) {
                    return part
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    // =========================================================================
    // ZIP THEME PICKER & FILE / LOG EXPORT
    // =========================================================================
    private fun launchZipFilePicker(result: MethodChannel.Result) {
        if (pendingZipPickResult != null) {
            result.error("BUSY", "Another file picker operation is in progress", null)
            return
        }
        pendingZipPickResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("application/zip", "application/x-zip-compressed", "application/octet-stream")
                )
            }
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_ZIP)
        } catch (t: Throwable) {
            pendingZipPickResult = null
            result.error("PICKER_ERROR", t.message, null)
        }
    }

    private fun saveOrShareBinaryFile(bytes: ByteArray, fileName: String, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("BUSY", "Another save operation is in progress", null)
            return
        }
        pendingSaveBytes = bytes
        pendingSaveResult = result
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, fileName)
            }
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_SAVE_FILE)
        } catch (_: Throwable) {
            pendingSaveBytes = null
            pendingSaveResult = null
            result.success(false)
        }
    }

    private fun shareTextContent(text: String, fileName: String) {
        try {
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, fileName)
                putExtra(Intent.EXTRA_TEXT, text)
            }
            startActivity(Intent.createChooser(sendIntent, "Chia sẻ $fileName"))
        } catch (_: Throwable) {}
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PICK_ZIP) {
            val res = pendingZipPickResult
            pendingZipPickResult = null
            if (res == null) return
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                res.success(null)
                return
            }
            val uri = data.data!!
            ioExecutor.execute {
                try {
                    val name = queryDisplayName(uri) ?: "theme.zip"
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    mainHandler.post {
                        if (bytes != null && bytes.isNotEmpty()) {
                            res.success(mapOf("name" to name, "bytes" to bytes))
                        } else {
                            res.success(null)
                        }
                    }
                } catch (t: Throwable) {
                    mainHandler.post {
                        res.error("READ_FAILED", t.message ?: "Cannot read ZIP file", null)
                    }
                }
            }
        } else if (requestCode == REQ_SAVE_FILE) {
            val res = pendingSaveResult
            val bytes = pendingSaveBytes
            pendingSaveResult = null
            pendingSaveBytes = null
            if (res == null) return
            if (resultCode != Activity.RESULT_OK || data?.data == null || bytes == null) {
                res.success(false)
                return
            }
            val uri = data.data!!
            ioExecutor.execute {
                try {
                    contentResolver.openOutputStream(uri)?.use { out ->
                        out.write(bytes)
                        out.flush()
                    }
                    mainHandler.post { res.success(true) }
                } catch (_: Throwable) {
                    mainHandler.post { res.success(false) }
                }
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) cursor.getString(idx) else null
            } else null
        } catch (_: Throwable) {
            null
        } finally {
            cursor?.close()
        }
    }

    // =========================================================================
    // NATIVE HARDWARE-ACCELERATED RGBA -> JPEG & MAN 3 HUD / ROAD LABEL CANVAS
    // Mirrors ios/Runner/AppDelegate.swift (drawRoadLabels & drawNavigationHud)
    // =========================================================================
    private fun renderAndCompressRgbaToJpeg(
        rgba: ByteArray,
        width: Int,
        height: Int,
        quality: Int,
        isDark: Boolean,
        roadLabels: List<Map<String, Any>>?,
        hud: Map<String, Any>?
    ): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba, 0, width * height * 4))

        val canvas = Canvas(bitmap)
        if (!roadLabels.isNullOrEmpty()) {
            drawRoadLabels(canvas, roadLabels, isDark)
        }
        if (hud != null) {
            drawNavigationHud(canvas, hud, width.toFloat(), height.toFloat())
        }

        val out = ByteArrayOutputStream(16384)
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(10, 100), out)
        bitmap.recycle()
        return out.toByteArray()
    }

    private fun drawRoadLabels(
        canvas: Canvas,
        labels: List<Map<String, Any>>,
        isDark: Boolean
    ) {
        val fgColor = if (isDark) {
            Color.rgb(245, 250, 255)
        } else {
            Color.rgb(20, 28, 41)
        }
        val haloColor = if (isDark) {
            Color.argb(245, 15, 23, 36)
        } else {
            Color.argb(250, 255, 255, 255)
        }

        val haloPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = boldSansTypeface
            style = Paint.Style.STROKE
            strokeWidth = 3.2f
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
            color = haloColor
        }
        val fillPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = boldSansTypeface
            style = Paint.Style.FILL
            color = fgColor
        }

        for (item in labels) {
            val rawText = ((item["text"] as? String) ?: (item["name"] as? String))?.trim() ?: continue
            if (rawText.isEmpty()) continue
            val sx = ((item["sx"] as? Number) ?: (item["x"] as? Number))?.toFloat() ?: continue
            val sy = ((item["sy"] as? Number) ?: (item["y"] as? Number))?.toFloat() ?: continue
            val angleDeg = (item["angleDeg"] as? Number)?.toFloat()
                ?: ((item["angle"] as? Number)?.toFloat()?.let { Math.toDegrees(it.toDouble()).toFloat() } ?: 0f)
            val tier = (item["tier"] as? Number)?.toInt() ?: if ((item["major"] as? Boolean) == true) 3 else 1

            val fontSize = if (tier >= 3) 10.0f else 8.8f
            haloPaint.textSize = fontSize
            fillPaint.textSize = fontSize

            val textWidth = fillPaint.measureText(rawText)
            val fm = fillPaint.fontMetrics
            val baselineY = -(fm.ascent + fm.descent) / 2f

            canvas.save()
            canvas.translate(sx, sy)
            canvas.rotate(angleDeg)
            canvas.drawText(rawText, -textWidth / 2f, baselineY, haloPaint)
            canvas.drawText(rawText, -textWidth / 2f, baselineY, fillPaint)
            canvas.restore()
        }
    }

    private fun drawNavigationHud(
        canvas: Canvas,
        hud: Map<String, Any>,
        width: Float,
        height: Float
    ) {
        val vx = (hud["vx"] as? Number)?.toFloat() ?: (width * 0.65f)
        val vy = (hud["vy"] as? Number)?.toFloat() ?: (height * 0.74f)
        val curRoadText = ((hud["curRoad"] as? String) ?: "Đường hiện tại").trim()
        val roadText = ((hud["nextStreet"] as? String) ?: (hud["road"] as? String) ?: "Đi thẳng").trim()
        val distText = ((hud["distStr"] as? String) ?: (hud["dist"] as? String) ?: "0 m").trim()
        val turnCodeAny = hud["turnCode"] ?: hud["turn"] ?: 0
        val speedStr = ((hud["speedStr"] as? String) ?: (hud["speed"]?.toString()) ?: "0").trim()
        val durText = ((hud["etaText"] as? String) ?: (hud["dur"] as? String) ?: "1 phút").trim()
        val subStr = ((hud["subText"] as? String) ?: run {
            val e = (hud["eta"] as? String) ?: "--:--"
            val r = (hud["remDist"] as? String) ?: ""
            "$e • $r"
        }).trim()
        val showCards = (hud["showCards"] as? Boolean) ?: true

        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
        }

        // 1. Google Maps 3D Vehicle Puck at (vx, vy)
        fillPaint.color = Color.argb(56, 26, 115, 232)
        canvas.drawCircle(vx, vy, 14.5f, fillPaint)

        fillPaint.color = Color.argb(90, 107, 138, 184)
        canvas.drawCircle(vx, vy + 0.5f, 10.8f, fillPaint)

        fillPaint.color = Color.WHITE
        canvas.drawCircle(vx, vy, 10.0f, fillPaint)

        val chevPath = Path().apply {
            moveTo(vx, vy - 5.8f)
            lineTo(vx + 4.8f, vy + 4.8f)
            lineTo(vx, vy + 1.8f)
            lineTo(vx - 4.8f, vy + 4.8f)
            close()
        }
        fillPaint.color = Color.rgb(26, 115, 232)
        canvas.drawPath(chevPath, fillPaint)

        // 2. Current Road Pill below vehicle puck
        if (curRoadText.isNotEmpty()) {
            textPaint.textSize = 9.5f
            textPaint.color = Color.WHITE
            val displayCurRoad = TextUtils.ellipsize(
                curRoadText,
                textPaint,
                118f,
                TextUtils.TruncateAt.END
            ).toString()
            val crW = textPaint.measureText(displayCurRoad)
            val pillW = (crW + 16f).coerceIn(54f, 134f)
            val pillH = 18f
            val pillX = (vx - pillW / 2f).coerceIn(138f, width - pillW - 4f)
            val pillY = (vy + 14f).coerceAtMost(height - pillH - 2f)
            val pillRect = RectF(pillX, pillY, pillX + pillW, pillY + pillH)

            fillPaint.color = Color.argb(245, 26, 115, 232)
            canvas.drawRoundRect(pillRect, 9f, 9f, fillPaint)

            strokePaint.color = Color.argb(230, 255, 255, 255)
            strokePaint.strokeWidth = 1.2f
            canvas.drawRoundRect(pillRect, 9f, 9f, strokePaint)

            val fm = textPaint.fontMetrics
            val tx = pillX + (pillW - crW) / 2f
            val ty = pillY + (pillH - (fm.descent - fm.ascent)) / 2f - fm.ascent
            canvas.drawText(displayCurRoad, tx, ty, textPaint)
        }

        if (!showCards) return

        val darkCardColor = Color.argb(238, 30, 31, 34)
        val borderGrayColor = Color.argb(46, 255, 255, 255)

        // 3. Top-Left Enlarged Black Maneuver Card + Coral-Red Badge Protruding Top-Left (matches iOS stream HUD)
        val topCardX = 4f
        val topCardY = 6f
        val topCardW = 138f
        val topCardH = 50f
        val topCardRect = RectF(topCardX, topCardY, topCardX + topCardW, topCardY + topCardH)

        fillPaint.color = Color.argb(77, 0, 0, 0)
        canvas.drawRoundRect(
            RectF(topCardX, topCardY + 2f, topCardX + topCardW, topCardY + topCardH + 2f),
            12f,
            12f,
            fillPaint
        )

        fillPaint.color = Color.argb(245, 9, 10, 15)
        canvas.drawRoundRect(topCardRect, 10f, 10f, fillPaint)
        strokePaint.color = Color.rgb(46, 48, 56)
        strokePaint.strokeWidth = 1.0f
        canvas.drawRoundRect(topCardRect, 10f, 10f, strokePaint)

        // Protruding Coral-Red distance pill at (x: 0, y: 2) outside black card
        textPaint.textSize = 12.0f
        val distTextW = textPaint.measureText(distText)
        val distPillW = maxOf(84f, distTextW + 34f).coerceAtMost(106f)
        val distPillH = 24f
        val coralRect = RectF(0f, 2f, distPillW, 2f + distPillH)
        fillPaint.color = Color.rgb(240, 98, 97)
        canvas.drawRoundRect(coralRect, 11f, 11f, fillPaint)

        val coralInnerRect = RectF(1.2f, 3.2f, distPillW - 1.2f, 2f + distPillH - 1.2f)
        strokePaint.color = Color.argb(217, 255, 255, 255)
        strokePaint.strokeWidth = 1.0f
        canvas.drawRoundRect(coralInnerRect, 10f, 10f, strokePaint)

        // Enlarged Turn icon centered at (15, 14) inside protruding coral badge
        drawTurnIcon(canvas, turnCodeAny, 15.0f, 14.0f, 8.6f)

        // Distance text inside coral pill
        textPaint.color = Color.WHITE
        val distFm = textPaint.fontMetrics
        val distTy = 2f + (distPillH - (distFm.descent - distFm.ascent)) / 2f - distFm.ascent
        canvas.drawText(distText, 27.0f, distTy, textPaint)

        // Next road name below coral pill (single line with crisp iOS-style marquee scroll when long)
        val streetDisplay = if (roadText.isNotEmpty()) roadText else "Đi thẳng"
        textPaint.textSize = 12.0f
        textPaint.color = Color.rgb(248, 250, 252)
        val streetW = textPaint.measureText(streetDisplay)
        val streetAvailW = 120.0f
        val streetFm = textPaint.fontMetrics
        val streetBaselineY = 28.0f - streetFm.ascent
        if (streetW > streetAvailW) {
            val loopDist = streetW + 36.0f
            val nowMs = System.currentTimeMillis()
            val cycleMs = (loopDist * 35.0f).toLong().coerceAtLeast(1L)
            val totalCycle = cycleMs + 2000L
            val phaseMs = nowMs % totalCycle
            val scrollX = when {
                phaseMs < 1200L -> 0.0f
                phaseMs > cycleMs + 1200L -> 0.0f
                else -> (phaseMs - 1200L).toFloat() / 35.0f
            }
            val off = scrollX % loopDist
            canvas.save()
            canvas.clipRect(8.0f, 26.0f, 8.0f + streetAvailW + 4.0f, 52.0f)
            canvas.drawText(streetDisplay, 10.0f - off, streetBaselineY, textPaint)
            canvas.drawText(streetDisplay, 10.0f - off + loopDist, streetBaselineY, textPaint)
            canvas.restore()
        } else {
            canvas.drawText(streetDisplay, 10.0f, streetBaselineY, textPaint)
        }

        // 4. Speedometer Box placed above Bottom-Left Time Card (matches iOS HUD cyan border)
        val spdRect = RectF(4f, 118f, 4f + 54f, 118f + 40f)
        fillPaint.color = Color.argb(242, 24, 25, 30)
        canvas.drawRoundRect(spdRect, 12f, 12f, fillPaint)
        strokePaint.color = Color.argb(230, 56, 189, 248)
        strokePaint.strokeWidth = 1.4f
        canvas.drawRoundRect(spdRect, 12f, 12f, strokePaint)

        textPaint.textSize = 16.5f
        textPaint.color = Color.WHITE
        val spdStrW = textPaint.measureText(speedStr)
        val spdFm = textPaint.fontMetrics
        canvas.drawText(speedStr, 4f + (54f - spdStrW) / 2f, 121f - spdFm.ascent, textPaint)

        val unitPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            textSize = 9.0f
            color = Color.rgb(148, 163, 184)
        }
        val unitW = unitPaint.measureText("km/h")
        val unitFm = unitPaint.fontMetrics
        canvas.drawText("km/h", 4f + (54f - unitW) / 2f, 142f - unitFm.ascent, unitPaint)

        // 5. Enlarged Bottom-Left Dark Trip Summary Card (x: 4, y: 166, w: 124, h: 42)
        val btmRect = RectF(4f, 166f, 4f + 124f, 166f + 42f)
        fillPaint.color = Color.argb(245, 30, 32, 37)
        canvas.drawRoundRect(btmRect, 12f, 12f, fillPaint)
        strokePaint.color = Color.rgb(63, 63, 70)
        strokePaint.strokeWidth = 1.0f
        canvas.drawRoundRect(btmRect, 12f, 12f, strokePaint)

        // Left '✕' circle at (19, 187), r=10
        val xCircleCx = 19f
        val xCircleCy = 187f
        fillPaint.color = Color.rgb(56, 57, 62)
        canvas.drawCircle(xCircleCx, xCircleCy, 10f, fillPaint)

        strokePaint.color = Color.WHITE
        strokePaint.strokeWidth = 2.0f
        strokePaint.strokeCap = Paint.Cap.ROUND
        canvas.drawLine(15.7f, 183.7f, 22.3f, 190.3f, strokePaint)
        canvas.drawLine(22.3f, 183.7f, 15.7f, 190.3f, strokePaint)

        // Duration line (bold white)
        textPaint.textSize = 13.0f
        textPaint.color = Color.WHITE
        val durDisplay = TextUtils.ellipsize(durText, textPaint, 90f, TextUtils.TruncateAt.END).toString()
        val durFm = textPaint.fontMetrics
        canvas.drawText(durDisplay, 34f, 170f - durFm.ascent, textPaint)

        // Subtitle: "ETA • remDist"
        unitPaint.textSize = 10.5f
        unitPaint.color = Color.rgb(228, 228, 231)
        val subDisplay = TextUtils.ellipsize(subStr, unitPaint, 90f, TextUtils.TruncateAt.END).toString()
        val subFm = unitPaint.fontMetrics
        canvas.drawText(subDisplay, 34f, 188f - subFm.ascent, unitPaint)
    }

    private fun drawTurnIcon(
        canvas: Canvas,
        turnCodeAny: Any,
        cx: Float,
        cy: Float,
        r: Float
    ) {
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 2.4f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        val codeInt = (turnCodeAny as? Number)?.toInt()
        val codeStr = turnCodeAny.toString().lowercase()
        // Matches EspNavPayload & ESP32 firmware:
        // 0: straight, 1: slight right, 2: right, 3: sharp right, 4: U-turn,
        // 5: sharp left, 6: left, 7: slight left, 8: roundabout, 9: arrive
        val isLeft = codeInt == 5 || codeInt == 6 || codeInt == 7 || codeStr.contains("left")
        val isRight = codeInt == 1 || codeInt == 2 || codeInt == 3 || codeStr.contains("right")
        val isUturn = codeInt == 4 || codeStr.contains("uturn") || codeStr.contains("u-turn")
        val isRoundabout = codeInt == 8 || codeStr.contains("roundabout")
        val isArrive = codeInt == 9 || codeStr.contains("arrive")

        val path = Path()
        when {
            isUturn -> {
                path.moveTo(cx + r * 0.45f, cy + r * 0.78f)
                path.lineTo(cx + r * 0.45f, cy - r * 0.15f)
                val arcRect = RectF(cx - r * 0.45f, cy - r * 0.72f, cx + r * 0.45f, cy + r * 0.18f)
                path.arcTo(arcRect, 0f, -180f)
                path.lineTo(cx - r * 0.45f, cy + r * 0.55f)
                canvas.drawPath(path, p)

                val head = Path().apply {
                    moveTo(cx - r * 0.80f, cy + r * 0.22f)
                    lineTo(cx - r * 0.45f, cy + r * 0.65f)
                    lineTo(cx - r * 0.10f, cy + r * 0.22f)
                }
                canvas.drawPath(head, p)
            }
            isRoundabout -> {
                canvas.drawCircle(cx, cy + r * 0.08f, r * 0.42f, p)
                canvas.drawLine(cx, cy + r * 0.80f, cx, cy + r * 0.50f, p)
                canvas.drawLine(cx + r * 0.30f, cy - r * 0.22f, cx + r * 0.68f, cy - r * 0.60f, p)
                val head = Path().apply {
                    moveTo(cx + r * 0.28f, cy - r * 0.62f)
                    lineTo(cx + r * 0.72f, cy - r * 0.64f)
                    lineTo(cx + r * 0.70f, cy - r * 0.20f)
                }
                canvas.drawPath(head, p)
            }
            isArrive -> {
                canvas.drawLine(cx - r * 0.40f, cy - r * 0.70f, cx - r * 0.40f, cy + r * 0.78f, p)
                val flagPaint = Paint(p).apply { style = Paint.Style.FILL }
                val flag = Path().apply {
                    moveTo(cx - r * 0.40f, cy - r * 0.70f)
                    lineTo(cx + r * 0.68f, cy - r * 0.32f)
                    lineTo(cx - r * 0.40f, cy + r * 0.06f)
                    close()
                }
                canvas.drawPath(flag, flagPaint)
            }
            codeInt == 7 -> { // Slight left
                path.moveTo(cx + r * 0.22f, cy + r * 0.78f)
                path.lineTo(cx + r * 0.22f, cy + r * 0.05f)
                path.lineTo(cx - r * 0.48f, cy - r * 0.62f)
                canvas.drawPath(path, p)
                val head = Path().apply {
                    moveTo(cx - r * 0.55f, cy - r * 0.16f)
                    lineTo(cx - r * 0.52f, cy - r * 0.66f)
                    lineTo(cx - r * 0.02f, cy - r * 0.63f)
                }
                canvas.drawPath(head, p)
            }
            codeInt == 1 -> { // Slight right
                path.moveTo(cx - r * 0.22f, cy + r * 0.78f)
                path.lineTo(cx - r * 0.22f, cy + r * 0.05f)
                path.lineTo(cx + r * 0.48f, cy - r * 0.62f)
                canvas.drawPath(path, p)
                val head = Path().apply {
                    moveTo(cx + r * 0.02f, cy - r * 0.63f)
                    lineTo(cx + r * 0.52f, cy - r * 0.66f)
                    lineTo(cx + r * 0.55f, cy - r * 0.16f)
                }
                canvas.drawPath(head, p)
            }
            isLeft -> {
                path.moveTo(cx + r * 0.35f, cy + r * 0.78f)
                path.lineTo(cx + r * 0.35f, cy - r * 0.20f)
                path.lineTo(cx - r * 0.68f, cy - r * 0.20f)
                canvas.drawPath(path, p)

                val head = Path().apply {
                    moveTo(cx - r * 0.26f, cy - r * 0.64f)
                    lineTo(cx - r * 0.72f, cy - r * 0.20f)
                    lineTo(cx - r * 0.26f, cy + r * 0.24f)
                }
                canvas.drawPath(head, p)
            }
            isRight -> {
                path.moveTo(cx - r * 0.35f, cy + r * 0.78f)
                path.lineTo(cx - r * 0.35f, cy - r * 0.20f)
                path.lineTo(cx + r * 0.68f, cy - r * 0.20f)
                canvas.drawPath(path, p)

                val head = Path().apply {
                    moveTo(cx + r * 0.26f, cy - r * 0.64f)
                    lineTo(cx + r * 0.72f, cy - r * 0.20f)
                    lineTo(cx + r * 0.26f, cy + r * 0.24f)
                }
                canvas.drawPath(head, p)
            }
            else -> {
                canvas.drawLine(cx, cy + r * 0.78f, cx, cy - r * 0.68f, p)
                val head = Path().apply {
                    moveTo(cx - r * 0.52f, cy - r * 0.18f)
                    lineTo(cx, cy - r * 0.74f)
                    lineTo(cx + r * 0.52f, cy - r * 0.18f)
                }
                canvas.drawPath(head, p)
            }
        }
    }

    // =========================================================================
    // WIFI SOFTAP TCP RELAY (Allows streaming to 192.168.4.1 even when 4G/5G is ON)
    // =========================================================================
    @Suppress("DEPRECATION")
    private fun openWifiApTcpRelay(host: String, port: Int): Int? {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
            val wifiNetworks = mutableListOf<Pair<Int, Network>>()
            for (net in cm.allNetworks) {
                val caps = cm.getNetworkCapabilities(net) ?: continue
                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                val lp = cm.getLinkProperties(net)
                val hasSoftApIp = lp?.linkAddresses?.any {
                    it.address.hostAddress?.startsWith("192.168.4.") == true
                } == true || lp?.dhcpServerAddress?.hostAddress == host
                wifiNetworks.add((if (hasSoftApIp) 0 else 1) to net)
            }
            if (wifiNetworks.isEmpty()) return null
            wifiNetworks.sortBy { it.first }

            var espSocket: Socket? = null
            for ((_, wifiNet) in wifiNetworks) {
                try {
                    val candidate = wifiNet.socketFactory.createSocket()
                    candidate.tcpNoDelay = true
                    candidate.connect(InetSocketAddress(host, port), 850)
                    espSocket = candidate
                    break
                } catch (_: Throwable) {}
            }
            val connectedEsp = espSocket ?: return null

            val localServer = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
            localServer.soTimeout = 3000
            val relayPort = localServer.localPort

            Thread({
                var localClient: Socket? = null
                try {
                    localClient = localServer.accept()
                    localClient.tcpNoDelay = true
                    try {
                        localServer.close()
                    } catch (_: Throwable) {}

                    val upstreamThread = Thread({
                        pumpStream(localClient.getInputStream(), connectedEsp.getOutputStream())
                        try { connectedEsp.shutdownOutput() } catch (_: Throwable) {}
                    }, "esp-relay-up")
                    upstreamThread.isDaemon = true
                    upstreamThread.start()

                    pumpStream(connectedEsp.getInputStream(), localClient.getOutputStream())
                    try { upstreamThread.join(300) } catch (_: Throwable) {}
                } catch (_: Throwable) {
                } finally {
                    try { localServer.close() } catch (_: Throwable) {}
                    try { localClient?.close() } catch (_: Throwable) {}
                    try { connectedEsp.close() } catch (_: Throwable) {}
                }
            }, "esp-relay-accept-$relayPort").apply {
                isDaemon = true
                start()
            }

            relayPort
        } catch (_: Throwable) {
            null
        }
    }

    private fun pumpStream(input: java.io.InputStream, output: java.io.OutputStream) {
        val buf = ByteArray(16384)
        try {
            while (true) {
                val read = input.read(buf)
                if (read < 0) break
                if (read > 0) {
                    output.write(buf, 0, read)
                    output.flush()
                }
            }
        } catch (_: Throwable) {}
    }
}
