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
    }

    val mainHandler = Handler(Looper.getMainLooper())
    private val imageExecutor = Executors.newFixedThreadPool(2)
    private val ioExecutor = Executors.newSingleThreadExecutor()

    var locationChannel: MethodChannel? = null
    var mediaChannel: MethodChannel? = null
    var callChannel: MethodChannel? = null
    var appleMapsChannel: MethodChannel? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private var tts: TextToSpeech? = null
    private var ttsReady = false
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
    }

    override fun onDestroy() {
        stopBackgroundLocks()
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
                    startBackgroundLocks()
                    result.success(true)
                }
                "stopBackgroundNavigation" -> {
                    stopBackgroundLocks()
                    result.success(true)
                }
                "speakGuidance" -> {
                    val args = call.arguments as? Map<*, *>
                    val text = (args?.get("text") as? String)?.trim() ?: ""
                    if (text.isNotEmpty()) {
                        speakVietnameseGuidance(text)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "stopGuidance" -> {
                    try {
                        tts?.stop()
                        abandonAudioFocus()
                    } catch (_: Throwable) {}
                    result.success(true)
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
            .maxWithOrNull(compareBy<Location> { it.time }.thenBy { -it.accuracy })

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
    private fun startBackgroundLocks() {
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
    }

    private fun stopBackgroundLocks() {
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
    private fun initTextToSpeech() {
        try {
            tts = TextToSpeech(applicationContext) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    val viLocale = Locale("vi", "VN")
                    val res = tts?.setLanguage(viLocale)
                    if (res != TextToSpeech.LANG_MISSING_DATA && res != TextToSpeech.LANG_NOT_SUPPORTED) {
                        ttsReady = true
                    } else {
                        tts?.language = Locale.getDefault()
                        ttsReady = true
                    }
                    tts?.setSpeechRate(1.05f)
                    tts?.setPitch(1.0f)
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}
                        override fun onDone(utteranceId: String?) {
                            abandonAudioFocus()
                        }
                        @Deprecated("Deprecated in Java")
                        override fun onError(utteranceId: String?) {
                            abandonAudioFocus()
                        }
                    })
                }
            }
        } catch (_: Throwable) {}
    }

    private fun speakVietnameseGuidance(text: String) {
        if (!ttsReady || tts == null) return
        try {
            requestDuckingAudioFocus()
            val params = Bundle().apply {
                putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
            }
            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, params, "esp32_nav_tts_${System.currentTimeMillis()}")
        } catch (_: Throwable) {}
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
    private fun reverseGeocodeStreetNative(lat: Double, lon: Double): String? {
        if (!Geocoder.isPresent()) return null
        return try {
            val geocoder = Geocoder(this, Locale("vi", "VN"))
            @Suppress("DEPRECATION")
            val list = geocoder.getFromLocation(lat, lon, 3)
            if (list.isNullOrEmpty()) return null
            for (addr in list) {
                val thoroughfare = addr.thoroughfare?.trim()
                if (!thoroughfare.isNullOrEmpty() && !thoroughfare.matches(Regex("^\\d+$"))) {
                    return thoroughfare
                }
            }
            val firstLine = list[0].getAddressLine(0) ?: return null
            val parts = firstLine.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            if (parts.isNotEmpty()) parts[0] else null
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
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            style = Paint.Style.STROKE
            strokeWidth = 3.2f
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
            color = haloColor
        }
        val fillPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
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

        // 3. Top-Left Maneuver Card + Coral Distance Pill
        val topCardX = 6f
        val topCardY = 6f
        val topCardW = 136f
        val topCardH = 54f
        val topCardRect = RectF(topCardX, topCardY, topCardX + topCardW, topCardY + topCardH)

        fillPaint.color = darkCardColor
        canvas.drawRoundRect(topCardRect, 11f, 11f, fillPaint)
        strokePaint.color = borderGrayColor
        strokePaint.strokeWidth = 1.0f
        canvas.drawRoundRect(topCardRect, 11f, 11f, strokePaint)

        // Coral/Red distance pill (#EE675C) at top-left
        val distPillW = 72f
        val distPillH = 22f
        val distPillRect = RectF(topCardX, topCardY, topCardX + distPillW, topCardY + distPillH)
        fillPaint.color = Color.rgb(238, 103, 92)
        canvas.drawRoundRect(distPillRect, 11f, 11f, fillPaint)

        // Turn icon inside coral pill
        drawTurnIcon(canvas, turnCodeAny, topCardX + 12f, topCardY + 11f, 6.5f)

        // Distance text inside coral pill
        textPaint.textSize = 11.0f
        textPaint.color = Color.WHITE
        val distFm = textPaint.fontMetrics
        val distTy = topCardY + (distPillH - (distFm.descent - distFm.ascent)) / 2f - distFm.ascent
        canvas.drawText(distText, topCardX + 22f, distTy, textPaint)

        // Next road name below coral pill (up to 2 lines)
        if (roadText.isNotEmpty()) {
            textPaint.textSize = 10.5f
            textPaint.color = Color.WHITE
            val maxLineW = topCardW - 14f
            val words = roadText.split(" ")
            var line1 = ""
            var line2 = ""
            for (w in words) {
                val test = if (line1.isEmpty()) w else "$line1 $w"
                if (textPaint.measureText(test) <= maxLineW) {
                    line1 = test
                } else {
                    line2 = if (line2.isEmpty()) w else "$line2 $w"
                }
            }
            if (line1.isEmpty()) {
                line1 = TextUtils.ellipsize(roadText, textPaint, maxLineW, TextUtils.TruncateAt.END).toString()
            } else if (line2.isNotEmpty()) {
                line2 = TextUtils.ellipsize(line2, textPaint, maxLineW, TextUtils.TruncateAt.END).toString()
            }
            val rFm = textPaint.fontMetrics
            if (line2.isEmpty()) {
                canvas.drawText(line1, topCardX + 7f, topCardY + 26f - rFm.ascent, textPaint)
            } else {
                textPaint.textSize = 9.5f
                val rFm2 = textPaint.fontMetrics
                canvas.drawText(line1, topCardX + 7f, topCardY + 23f - rFm2.ascent, textPaint)
                canvas.drawText(line2, topCardX + 7f, topCardY + 35f - rFm2.ascent, textPaint)
            }
        }

        // 4. Speedometer Box (Bottom-left above trip card)
        val btmCardY = height - 48f
        val spdW = 48f
        val spdH = 44f
        val spdX = 6f
        val spdY = btmCardY - spdH - 6f
        val spdRect = RectF(spdX, spdY, spdX + spdW, spdY + spdH)

        fillPaint.color = darkCardColor
        canvas.drawRoundRect(spdRect, 11f, 11f, fillPaint)
        strokePaint.color = borderGrayColor
        strokePaint.strokeWidth = 1.0f
        canvas.drawRoundRect(spdRect, 11f, 11f, strokePaint)

        textPaint.textSize = 16.0f
        textPaint.color = Color.WHITE
        val spdStrW = textPaint.measureText(speedStr)
        val spdFm = textPaint.fontMetrics
        canvas.drawText(speedStr, spdX + (spdW - spdStrW) / 2f, spdY + 5f - spdFm.ascent, textPaint)

        val unitPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.NORMAL)
            textSize = 8.5f
            color = Color.rgb(189, 193, 198)
        }
        val unitW = unitPaint.measureText("km/h")
        val unitFm = unitPaint.fontMetrics
        canvas.drawText("km/h", spdX + (spdW - unitW) / 2f, spdY + 26f - unitFm.ascent, unitPaint)

        // 5. Bottom-Left Trip Summary Card (Duration + ETA • Remaining Distance)
        val btmCardX = 6f
        val btmCardW = 126f
        val btmCardH = 42f
        val btmRect = RectF(btmCardX, btmCardY, btmCardX + btmCardW, btmCardY + btmCardH)

        fillPaint.color = darkCardColor
        canvas.drawRoundRect(btmRect, 11f, 11f, fillPaint)
        strokePaint.color = borderGrayColor
        strokePaint.strokeWidth = 1.0f
        canvas.drawRoundRect(btmRect, 11f, 11f, strokePaint)

        // Small 'X' close circle on the left of bottom card
        val xCircleCx = btmCardX + 14f
        val xCircleCy = btmCardY + btmCardH / 2f
        fillPaint.color = Color.rgb(60, 64, 67)
        canvas.drawCircle(xCircleCx, xCircleCy, 9f, fillPaint)

        strokePaint.color = Color.rgb(232, 234, 237)
        strokePaint.strokeWidth = 1.6f
        strokePaint.strokeCap = Paint.Cap.ROUND
        canvas.drawLine(xCircleCx - 3.2f, xCircleCy - 3.2f, xCircleCx + 3.2f, xCircleCy + 3.2f, strokePaint)
        canvas.drawLine(xCircleCx - 3.2f, xCircleCy + 3.2f, xCircleCx + 3.2f, xCircleCy - 3.2f, strokePaint)

        // Duration line (bold white)
        textPaint.textSize = 11.5f
        textPaint.color = Color.WHITE
        val durDisplay = TextUtils.ellipsize(durText, textPaint, btmCardW - 30f, TextUtils.TruncateAt.END).toString()
        val durFm = textPaint.fontMetrics
        canvas.drawText(durDisplay, btmCardX + 27f, btmCardY + 6f - durFm.ascent, textPaint)

        // Subtitle: "ETA • remDist"
        unitPaint.textSize = 9.0f
        unitPaint.color = Color.rgb(189, 193, 198)
        val subDisplay = TextUtils.ellipsize(subStr, unitPaint, btmCardW - 30f, TextUtils.TruncateAt.END).toString()
        val subFm = unitPaint.fontMetrics
        canvas.drawText(subDisplay, btmCardX + 27f, btmCardY + 23f - subFm.ascent, unitPaint)
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
            strokeWidth = 1.8f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        val codeInt = (turnCodeAny as? Number)?.toInt()
        val codeStr = turnCodeAny.toString().lowercase()
        val isLeft = codeInt == 1 || codeInt == 3 || codeInt == 5 || codeStr.contains("left")
        val isRight = codeInt == 2 || codeInt == 4 || codeInt == 6 || codeStr.contains("right")
        val isUturn = codeInt == 7 || codeStr.contains("uturn")

        val path = Path()
        when {
            isLeft -> {
                path.moveTo(cx + r * 0.3f, cy + r * 0.8f)
                path.lineTo(cx + r * 0.3f, cy - r * 0.2f)
                path.lineTo(cx - r * 0.7f, cy - r * 0.2f)
                canvas.drawPath(path, p)

                val head = Path().apply {
                    moveTo(cx - r * 0.3f, cy - r * 0.65f)
                    lineTo(cx - r * 0.75f, cy - r * 0.2f)
                    lineTo(cx - r * 0.3f, cy + r * 0.25f)
                }
                canvas.drawPath(head, p)
            }
            isRight -> {
                path.moveTo(cx - r * 0.3f, cy + r * 0.8f)
                path.lineTo(cx - r * 0.3f, cy - r * 0.2f)
                path.lineTo(cx + r * 0.7f, cy - r * 0.2f)
                canvas.drawPath(path, p)

                val head = Path().apply {
                    moveTo(cx + r * 0.3f, cy - r * 0.65f)
                    lineTo(cx + r * 0.75f, cy - r * 0.2f)
                    lineTo(cx + r * 0.3f, cy + r * 0.25f)
                }
                canvas.drawPath(head, p)
            }
            isUturn -> {
                path.moveTo(cx + r * 0.45f, cy + r * 0.8f)
                path.lineTo(cx + r * 0.45f, cy - r * 0.2f)
                val arcRect = RectF(cx - r * 0.45f, cy - r * 0.75f, cx + r * 0.45f, cy + r * 0.15f)
                path.arcTo(arcRect, 0f, -180f)
                path.lineTo(cx - r * 0.45f, cy + r * 0.55f)
                canvas.drawPath(path, p)

                val head = Path().apply {
                    moveTo(cx - r * 0.8f, cy + r * 0.2f)
                    lineTo(cx - r * 0.45f, cy + r * 0.65f)
                    lineTo(cx - r * 0.1f, cy + r * 0.2f)
                }
                canvas.drawPath(head, p)
            }
            else -> {
                canvas.drawLine(cx, cy + r * 0.8f, cx, cy - r * 0.7f, p)
                val head = Path().apply {
                    moveTo(cx - r * 0.5f, cy - r * 0.2f)
                    lineTo(cx, cy - r * 0.75f)
                    lineTo(cx + r * 0.5f, cy - r * 0.2f)
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
