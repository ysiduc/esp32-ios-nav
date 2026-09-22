import Flutter
import UIKit
import MediaPlayer
import CallKit
import CoreLocation
import MapKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaChannel: FlutterMethodChannel?
  private var callChannel: FlutterMethodChannel?
  private var locationChannel: FlutterMethodChannel?
  private var searchChannel: FlutterMethodChannel?
  private var accessibilityChannel: FlutterMethodChannel?
  private var glassHostChannel: FlutterMethodChannel?
  private var reduceTransparencyObserver: NSObjectProtocol?
  private var isChannelSetup = false
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  // CallKit observer - theo dõi cuộc gọi
  private var callObserver: CXCallObserver?
  private var callObserverDelegate: CallObserverDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      setupChannels(binaryMessenger: controller.binaryMessenger)
      let registrar = self.registrar(forPlugin: "NativeGlassPlugin")
      registrar?.register(
        NativeGlassPlatformViewFactory(messenger: controller.binaryMessenger),
        withId: "plugins.ysiduc.com/native_glass"
      )
      registrar?.register(
        NativeGlassHostPlatformViewFactory(messenger: controller.binaryMessenger),
        withId: "plugins.ysiduc.com/native_glass_host"
      )
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    backgroundTask = application.beginBackgroundTask(withName: "ESP32NavBackgroundKeepAlive") { [weak self] in
      if let task = self?.backgroundTask, task != .invalid {
        application.endBackgroundTask(task)
        self?.backgroundTask = .invalid
      }
    }
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    if backgroundTask != .invalid {
      application.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaPlugin") {
      setupChannels(binaryMessenger: registrar.messenger())
    }
  }

  private func setupChannels(binaryMessenger: FlutterBinaryMessenger) {
    guard !isChannelSetup else { return }
    isChannelSetup = true
    UIDevice.current.isBatteryMonitoringEnabled = true

    // ─── 1. Media Channel (nhạc đang phát) ───────────────────────────────
    mediaChannel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/media",
      binaryMessenger: binaryMessenger
    )
    mediaChannel?.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "getNowPlaying" {
        self?.fetchCurrentNowPlaying(completion: { data in
          result(data)
        })
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Lắng nghe khi bài hát thay đổi
    MediaRemoteObserver.shared.onMediaChanged = { [weak self] title, artist, isPlaying in
      self?.mediaChannel?.invokeMethod(
        "onNowPlayingChanged",
        arguments: [
          "title": title,
          "artist": artist,
          "isPlaying": isPlaying
        ]
      )
    }

    // ─── 2. Call Channel (cuộc gọi đến) ──────────────────────────────────
    callChannel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/calls",
      binaryMessenger: binaryMessenger
    )

    // Không cần xử lý call từ Flutter phía iOS (chỉ gửi 1 chiều iOS → Flutter)
    callChannel?.setMethodCallHandler { (call, result) in
      result(FlutterMethodNotImplemented)
    }

    // ─── 3. Location Channel (Background Survival & MKMapSnapshotter) ────
    locationChannel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/location",
      binaryMessenger: binaryMessenger
    )
    locationChannel?.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "startBackgroundNavigation":
        NavigationLocationManager.shared.start()
        result(true)
      case "stopBackgroundNavigation":
        NavigationLocationManager.shared.stop()
        result(true)
      case "getBatteryLevel":
        UIDevice.current.isBatteryMonitoringEnabled = true
        let rawLevel = UIDevice.current.batteryLevel
        if rawLevel >= 0 {
          let percentage = Int(round(rawLevel * 100.0))
          result(percentage)
        } else {
          result(85)
        }
      case "shareLog":
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing log text", details: nil))
          return
        }
        let fileName = (args["fileName"] as? String) ?? "esp32_tx_rx_log.txt"
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
          try text.write(to: tempUrl, atomically: true, encoding: .utf8)
          DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: [tempUrl], applicationActivities: nil)
            let rootVC = self?.window?.rootViewController ?? UIApplication.shared.windows.first?.rootViewController
            if let popover = activityVC.popoverPresentationController, let rvc = rootVC {
              popover.sourceView = rvc.view
              popover.sourceRect = CGRect(x: rvc.view.bounds.midX, y: rvc.view.bounds.midY, width: 0, height: 0)
              popover.permittedArrowDirections = []
            }
            rootVC?.present(activityVC, animated: true, completion: nil)
            result(true)
          }
        } catch {
          result(FlutterError(code: "WRITE_ERROR", message: error.localizedDescription, details: nil))
        }
      case "getThermalState":
        let state: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = "nominal"
        case .fair: state = "fair"
        case .serious: state = "serious"
        case .critical: state = "critical"
        @unknown default: state = "nominal"
        }
        result(state)
      case "isLowPowerModeEnabled":
        result(ProcessInfo.processInfo.isLowPowerModeEnabled)
      case "renderMapSnapshot":
        guard let args = call.arguments as? [String: Any],
              let lat = args["lat"] as? Double,
              let lng = args["lng"] as? Double else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing lat/lng", details: nil))
          return
        }
        let width = (args["width"] as? Double) ?? 144.0
        let height = (args["height"] as? Double) ?? 208.0
        let spanMeters = (args["spanMeters"] as? Double) ?? 300.0

        MapStreamer.shared.renderSnapshot(
          coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
          width: width,
          height: height,
          spanMeters: spanMeters
        ) { jpegData in
          if let data = jpegData {
            result(FlutterStandardTypedData(bytes: data))
          } else {
            result(nil)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }


    // ─── 5. Accessibility Channel (Reduce Transparency & Glass Capability - P5.7.1, P5.7.2 & P5.8) ──
    accessibilityChannel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/accessibility",
      binaryMessenger: binaryMessenger
    )
    accessibilityChannel?.setMethodCallHandler { (call, result) in
      switch call.method {
      case "isReduceTransparencyEnabled":
        result(UIAccessibility.isReduceTransparencyEnabled)
      case "getGlassCapability":
        // P5.8: Honest capability reporting: "uiglass-container", "uiglass" when available, else "native-blur-fallback"
        if NativeGlassPlatformView.isGlassContainerAvailable {
          result("uiglass-container")
        } else if NativeGlassPlatformView.isTrueGlassAvailable {
          result("uiglass")
        } else {
          result("native-blur-fallback")
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ─── 6. Native Glass Host Channel (P5.8) ──────────────────────────
    glassHostChannel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/glass_host",
      binaryMessenger: binaryMessenger
    )
    glassHostChannel?.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setOverlayActive":
        let active = call.arguments as? Bool ?? false
        NativeGlassHostPlatformView.setOverlayActive(active)
        result(nil)
      case "updateSurfaces":
        if let surfaces = call.arguments as? [[String: Any]] {
          NativeGlassHostPlatformView.updateSurfaces(surfaces)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    if let existing = reduceTransparencyObserver {
      NotificationCenter.default.removeObserver(existing)
      reduceTransparencyObserver = nil
    }

    reduceTransparencyObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.accessibilityChannel?.invokeMethod(
        "onReduceTransparencyChanged",
        arguments: UIAccessibility.isReduceTransparencyEnabled
      )
    }

    // ─── 4. MapKit Search Channel ───────────────────────────────────────
    searchChannel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/mapkit_search",
      binaryMessenger: binaryMessenger
    )
    searchChannel?.setMethodCallHandler { (call, result) in
      Task { @MainActor in
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "autocomplete":
          guard let query = args?["query"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing query", details: nil))
            return
          }
          let userLat = args?["userLat"] as? Double
          let userLon = args?["userLon"] as? Double
          do {
            let completions = try await MapKitSearchBridge.shared.autocomplete(
              query: query,
              userLat: userLat,
              userLon: userLon
            )
            result(completions)
          } catch {
            result([])
          }

        case "resolve":
          guard let completionID = args?["completionID"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing completionID", details: nil))
            return
          }
          do {
            let place = try await MapKitSearchBridge.shared.resolve(completionID: completionID)
            result(place)
          } catch {
            result(nil)
          }

        case "search":
          guard let query = args?["query"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing query", details: nil))
            return
          }
          let userLat = args?["userLat"] as? Double
          let userLon = args?["userLon"] as? Double
          do {
            let places = try await MapKitSearchBridge.shared.search(
              query: query,
              userLat: userLat,
              userLon: userLon
            )
            result(places)
          } catch {
            result([])
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    // Khởi động CallKit observer
    setupCallObserver()
  }


  // ─── CallKit Observer Setup ───────────────────────────────────────────────
  private func setupCallObserver() {
    let delegate = CallObserverDelegate()
    delegate.onIncomingCall = { [weak self] callInfo in
      DispatchQueue.main.async {
        self?.callChannel?.invokeMethod("onIncomingCall", arguments: callInfo)
      }
    }
    delegate.onCallAnswered = { [weak self] callInfo in
      DispatchQueue.main.async {
        self?.callChannel?.invokeMethod("onCallAnswered", arguments: callInfo)
      }
    }
    delegate.onCallEnded = { [weak self] in
      DispatchQueue.main.async {
        self?.callChannel?.invokeMethod("onCallEnded", arguments: nil)
      }
    }

    callObserverDelegate = delegate
    callObserver = CXCallObserver()
    callObserver?.setDelegate(delegate, queue: DispatchQueue.main)
  }

  private func fetchCurrentNowPlaying(completion: @escaping ([String: Any]) -> Void) {
    MediaRemoteObserver.shared.fetchNowPlaying(completion: completion)
  }

  deinit {
    if let obs = reduceTransparencyObserver {
      NotificationCenter.default.removeObserver(obs)
      reduceTransparencyObserver = nil
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CallKit Observer Delegate
// ─────────────────────────────────────────────────────────────────────────────
class CallObserverDelegate: NSObject, CXCallObserverDelegate {
  var onIncomingCall: (([String: Any]) -> Void)?
  var onCallAnswered: (([String: Any]) -> Void)?
  var onCallEnded: (() -> Void)?

  private var lastCallUUID: UUID?
  private var lastCallInfo: [String: Any] = [:]

  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    // Cuộc gọi đến và chưa kết nối (đổ chuông)
    // CXCall không có thuộc tính `isIncoming`, dùng `!call.isOutgoing`
    if !call.isOutgoing && !call.hasConnected && !call.hasEnded {
      // Tránh gửi trùng lặp cho cùng 1 UUID
      if lastCallUUID == call.uuid { return }
      lastCallUUID = call.uuid

      // Lấy thông tin cuộc gọi đến
      resolveCallerInfo(call: call) { [weak self] info in
        self?.lastCallInfo = info
        self?.onIncomingCall?(info)
      }
    }

    // Đã kết nối (nghe máy)
    else if call.hasConnected && !call.hasEnded {
      if !lastCallInfo.isEmpty {
        onCallAnswered?(lastCallInfo)
      }
    }

    // Kết thúc cuộc gọi
    else if call.hasEnded {
      if lastCallUUID == call.uuid {
        lastCallUUID = nil
        lastCallInfo = [:]
        onCallEnded?()
      }
    }
  }

  /// Lấy thông tin cuộc gọi đến
  private func resolveCallerInfo(call: CXCall, completion: @escaping ([String: Any]) -> Void) {
    // CXCall trong iOS sandbox không cung cấp số/tên người gọi trực tiếp
    completion([
      "name": "Cuoc goi den",
      "number": "unknown",
      "uuid": call.uuid.uuidString
    ])
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Media Remote Observer (Nhạc đang phát)
// ─────────────────────────────────────────────────────────────────────────────
class MediaRemoteObserver {
  static let shared = MediaRemoteObserver()

  typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void
  typealias MRMediaRemoteRegisterFunction = @convention(c) (DispatchQueue) -> Void

  private var getNowPlayingInfoFunc: MRMediaRemoteGetNowPlayingInfoFunction?
  private var registerForNotificationsFunc: MRMediaRemoteRegisterFunction?

  var onMediaChanged: ((_ title: String, _ artist: String, _ isPlaying: Bool) -> Void)?

  init() {
    setupMediaRemote()
    setupSystemMusicPlayer()
  }

  private func setupMediaRemote() {
    if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) {
      if let getPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
        getNowPlayingInfoFunc = unsafeBitCast(getPtr, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
      }
      if let regPtr = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
        registerForNotificationsFunc = unsafeBitCast(regPtr, to: MRMediaRemoteRegisterFunction.self)
      }
    }

    if let regFunc = registerForNotificationsFunc {
      regFunc(DispatchQueue.main)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(mediaDidChangeNotification),
        name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(mediaDidChangeNotification),
        name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        object: nil
      )
    }
  }

  private func setupSystemMusicPlayer() {
    let player = MPMusicPlayerController.systemMusicPlayer
    player.beginGeneratingPlaybackNotifications()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mediaDidChangeNotification),
      name: .MPMusicPlayerControllerNowPlayingItemDidChange,
      object: player
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mediaDidChangeNotification),
      name: .MPMusicPlayerControllerPlaybackStateDidChange,
      object: player
    )
  }

  @objc private func mediaDidChangeNotification() {
    fetchNowPlaying { [weak self] data in
      let title = (data["title"] as? String) ?? ""
      let artist = (data["artist"] as? String) ?? ""
      let isPlaying = (data["isPlaying"] as? Bool) ?? false
      self?.onMediaChanged?(title, artist, isPlaying)
    }
  }

  func fetchNowPlaying(completion: @escaping ([String: Any]) -> Void) {
    if let getInfo = getNowPlayingInfoFunc {
      getInfo(DispatchQueue.main) { [weak self] cfDict in
        let dict = cfDict as NSDictionary
        let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
        let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0.0
        let isPlaying = rate > 0.0

        if !title.isEmpty {
          completion([
            "title": title,
            "artist": artist,
            "isPlaying": isPlaying
          ])
          return
        }

        self?.fallbackToSystemMusicPlayer(completion: completion)
      }
    } else {
      fallbackToSystemMusicPlayer(completion: completion)
    }
  }

  private func fallbackToSystemMusicPlayer(completion: @escaping ([String: Any]) -> Void) {
    let player = MPMusicPlayerController.systemMusicPlayer
    if let item = player.nowPlayingItem, let title = item.title, !title.isEmpty {
      let artist = item.artist ?? ""
      let isPlaying = player.playbackState == .playing
      completion([
        "title": title,
        "artist": artist,
        "isPlaying": isPlaying
      ])
    } else {
      completion([
        "title": "",
        "artist": "",
        "isPlaying": false
      ])
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Background Keep-Alive Manager (Silent Audio Loop for 24/7 Network Survival)
// ─────────────────────────────────────────────────────────────────────────────
class BackgroundKeepAliveManager {
  static let shared = BackgroundKeepAliveManager()
  private var audioPlayer: AVAudioPlayer?
  private var isRunning = false

  func start() {
    guard !isRunning else { return }
    isRunning = true

    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try AVAudioSession.sharedInstance().setActive(true)

      if audioPlayer == nil {
        let silentWav = createSilentWav()
        audioPlayer = try AVAudioPlayer(data: silentWav)
        audioPlayer?.numberOfLoops = -1 // Loop infinitely
        audioPlayer?.volume = 0.001 // Inaudible, mixWithOthers prevents interfering with calls/music
        audioPlayer?.prepareToPlay()
      }
      audioPlayer?.play()
      print("[BackgroundKeepAlive] Silent audio keep-alive activated")
    } catch {
      print("[BackgroundKeepAlive] Audio keep-alive error: \(error)")
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    audioPlayer?.stop()
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {}
    print("[BackgroundKeepAlive] Silent audio keep-alive deactivated")
  }

  /// Generates a standard RIFF/WAVE 1-second 8kHz mono 16-bit PCM silence in memory (~16KB)
  private func createSilentWav() -> Data {
    let sampleRate: Int32 = 8000
    let numChannels: Int16 = 1
    let bitsPerSample: Int16 = 16
    let byteRate = sampleRate * Int32(numChannels * bitsPerSample / 8)
    let blockAlign = numChannels * bitsPerSample / 8
    let durationSeconds = 1
    let numSamples = Int(sampleRate) * durationSeconds
    let dataSize = Int32(numSamples * Int(blockAlign))
    let chunkSize = 36 + dataSize

    var data = Data()
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    var subchunk1Size: Int32 = 16
    data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Array($0) })
    var audioFormat: Int16 = 1 // PCM
    data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
    data.append(Data(count: Int(dataSize))) // Silence (all zero bytes)
    return data
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Navigation Location Manager (Background Survival & Blue Bar Indicator)
// ─────────────────────────────────────────────────────────────────────────────
class NavigationLocationManager: NSObject, CLLocationManagerDelegate {
  static let shared = NavigationLocationManager()
  let locationManager = CLLocationManager()
  private var isRunning = false

  override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    locationManager.activityType = .automotiveNavigation
    locationManager.distanceFilter = kCLDistanceFilterNone
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true

    if locationManager.authorizationStatus == .notDetermined {
      locationManager.requestAlwaysAuthorization()
    }

    // Crucial settings for iOS background execution:
    // Shows the active blue navigation bar/pill, preventing iOS from suspending CPU or killing Wi-Fi
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.showsBackgroundLocationIndicator = true
    locationManager.pausesLocationUpdatesAutomatically = false

    locationManager.startUpdatingLocation()
    locationManager.startUpdatingHeading()

    // Start silent audio loop to keep WebSocket Hotspot and BLE alive 24/7
    BackgroundKeepAliveManager.shared.start()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    locationManager.showsBackgroundLocationIndicator = false
    locationManager.stopUpdatingLocation()
    locationManager.stopUpdatingHeading()

    BackgroundKeepAliveManager.shared.stop()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Keeps background thread alive
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MapStreamer (MKMapSnapshotter for Off-Screen Background Map Rendering)
// ─────────────────────────────────────────────────────────────────────────────
class MapStreamer {
  static let shared = MapStreamer()

  func renderSnapshot(
    coordinate: CLLocationCoordinate2D,
    width: Double = 144.0,
    height: Double = 208.0,
    spanMeters: Double = 300.0,
    completion: @escaping (Data?) -> Void
  ) {
    let options = MKMapSnapshotter.Options()
    options.region = MKCoordinateRegion(
      center: coordinate,
      latitudinalMeters: spanMeters,
      longitudinalMeters: spanMeters
    )
    options.size = CGSize(width: width, height: height)
    options.scale = 1.0 // 1.0x scale for lightweight JPEG

    let snapshotter = MKMapSnapshotter(options: options)
    snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { snapshot, error in
      guard let snapshot = snapshot, error == nil else {
        completion(nil)
        return
      }

      let image = snapshot.image
      let jpegData = image.jpegData(compressionQuality: 0.40)
      completion(jpegData)
    }
  }
}



// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MapKitSearchBridge (Flutter Bridge for MKLocalSearch & Completer)
// ─────────────────────────────────────────────────────────────────────────────
class MapKitSearchBridge: NSObject, MKLocalSearchCompleterDelegate {
  static let shared = MapKitSearchBridge()

  private let completer = MKLocalSearchCompleter()
  private var pendingContinuation: CheckedContinuation<[[String: Any]], Error>?
  private var completionsCache: [String: MKLocalSearchCompletion] = [:]

  override init() {
    super.init()
    completer.resultTypes = [.address, .pointOfInterest, .query]
    completer.delegate = self
  }

  @MainActor
  func autocomplete(query: String, userLat: Double?, userLon: Double?) async throws -> [[String: Any]] {
    pendingContinuation?.resume(throwing: CancellationError())
    pendingContinuation = nil

    if let lat = userLat, let lon = userLon {
      completer.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
      )
    } else {
      completer.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 16.0, longitude: 106.0),
        span: MKCoordinateSpan(latitudeDelta: 10.0, longitudeDelta: 6.0)
      )
    }

    return try await withCheckedThrowingContinuation { continuation in
      self.pendingContinuation = continuation
      self.completer.queryFragment = query
    }
  }

  func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    Task { @MainActor in
      guard let continuation = self.pendingContinuation else { return }
      self.pendingContinuation = nil

      self.completionsCache.removeAll()
      var results: [[String: Any]] = []
      for item in completer.results {
        let id = UUID().uuidString
        self.completionsCache[id] = item
        results.append([
          "id": id,
          "title": item.title,
          "subtitle": item.subtitle,
          "precision": "poi"
        ])
      }
      continuation.resume(returning: results)
    }
  }

  func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    Task { @MainActor in
      guard let continuation = self.pendingContinuation else { return }
      self.pendingContinuation = nil
      continuation.resume(throwing: error)
    }
  }

  @MainActor
  func resolve(completionID: String) async throws -> [String: Any]? {
    guard let completion = completionsCache[completionID] else {
      return nil
    }

    let request = MKLocalSearch.Request(completion: completion)
    let search = MKLocalSearch(request: request)
    let response = try await search.start()
    guard let item = response.mapItems.first else { return nil }

    let coord = item.placemark.coordinate
    let title = item.name ?? completion.title
    let subtitle = item.placemark.title ?? completion.subtitle

    var precision = "poi"
    if item.placemark.subThoroughfare != nil {
      precision = "exactAddress"
    } else if item.pointOfInterestCategory != nil {
      precision = "poi"
    } else if item.placemark.thoroughfare != nil {
      precision = "street"
    } else if item.placemark.locality != nil || item.placemark.subAdministrativeArea != nil {
      precision = "district"
    }

    return [
      "id": completionID,
      "title": title,
      "subtitle": subtitle,
      "latitude": coord.latitude,
      "longitude": coord.longitude,
      "precision": precision
    ]
  }

  @MainActor
  func search(query: String, userLat: Double?, userLon: Double?) async throws -> [[String: Any]] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    if let lat = userLat, let lon = userLon {
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
      )
    }

    let search = MKLocalSearch(request: request)
    let response = try await search.start()
    var results: [[String: Any]] = []

    for item in response.mapItems {
      let coord = item.placemark.coordinate
      let title = item.name ?? query
      let subtitle = item.placemark.title ?? ""

      var precision = "poi"
      if item.placemark.subThoroughfare != nil {
        precision = "exactAddress"
      } else if item.pointOfInterestCategory != nil {
        precision = "poi"
      } else if item.placemark.thoroughfare != nil {
        precision = "street"
      } else if item.placemark.locality != nil {
        precision = "district"
      }

      results.append([
        "id": UUID().uuidString,
        "title": title,
        "subtitle": subtitle,
        "latitude": coord.latitude,
        "longitude": coord.longitude,
        "precision": precision
      ])
    }
    return results
  }

}


// MARK: - Native iOS Liquid Glass PlatformView & Host (P5.7, P5.7.1 & P5.8)

class NativeGlassPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private var messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativeGlassPlatformView(
      frame: frame,
      viewIdentifier: viewId,
      arguments: args,
      binaryMessenger: messenger
    )
  }

  public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class NativeGlassHostPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private var messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativeGlassHostPlatformView(
      frame: frame,
      viewIdentifier: viewId,
      arguments: args,
      binaryMessenger: messenger
    )
  }

  public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class NativeGlassPlatformView: NSObject, FlutterPlatformView {
  private var containerView: UIView

  static var isTrueGlassAvailable: Bool {
    if #available(iOS 26.0, *) {
      return NSClassFromString("UIGlassEffect") != nil
    }
    return false
  }

  static var isGlassContainerAvailable: Bool {
    if #available(iOS 26.0, *) {
      return NSClassFromString("UIGlassContainerEffect") != nil
    }
    return false
  }

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    binaryMessenger: FlutterBinaryMessenger?
  ) {
    let params = args as? [String: Any]
    let variant = params?["variant"] as? String ?? "regular"
    let cornerRadius = CGFloat(params?["radius"] as? Double ?? 20.0)
    let isSelected = params?["isSelected"] as? Bool ?? false

    var tintColor: UIColor? = nil
    if let tintVal = params?["tint"] as? Int64 {
      let a = CGFloat((tintVal >> 24) & 0xFF) / 255.0
      let r = CGFloat((tintVal >> 16) & 0xFF) / 255.0
      let g = CGFloat((tintVal >> 8) & 0xFF) / 255.0
      let b = CGFloat(tintVal & 0xFF) / 255.0
      tintColor = UIColor(red: r, green: g, blue: b, alpha: a)
    }

    containerView = NativeGlassPlatformView.createGlassEffectView(
      variant: variant,
      cornerRadius: cornerRadius,
      isSelected: isSelected,
      tintColorOverride: tintColor
    )
    containerView.frame = frame
    super.init()
  }

  func view() -> UIView {
    return containerView
  }

  static func createGlassContainerView(
    cornerRadius: CGFloat
  ) -> UIView {
    let container = UIView()
    container.backgroundColor = .clear
    container.layer.cornerRadius = cornerRadius
    container.layer.masksToBounds = true
    container.isUserInteractionEnabled = false

    if isGlassContainerAvailable, #available(iOS 26.0, *) {
      if let containerEffectClass = NSClassFromString("UIGlassContainerEffect") as? UIVisualEffect.Type {
        let effect = containerEffectClass.init()
        let effectView = UIVisualEffectView(effect: effect)
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.layer.cornerRadius = cornerRadius
        effectView.layer.masksToBounds = true
        effectView.isUserInteractionEnabled = false
        container.addSubview(effectView)
        return container
      }
    }

    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let effectView = UIVisualEffectView(effect: blurEffect)
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.layer.cornerRadius = cornerRadius
    effectView.layer.masksToBounds = true
    effectView.isUserInteractionEnabled = false
    container.addSubview(effectView)
    return container
  }

  static func createGlassEffectView(
    variant: String,
    cornerRadius: CGFloat,
    isSelected: Bool,
    tintColorOverride: UIColor? = nil
  ) -> UIView {
    let container = UIView()
    container.backgroundColor = .clear
    container.layer.cornerRadius = cornerRadius
    container.layer.masksToBounds = true
    container.isUserInteractionEnabled = false

    if isTrueGlassAvailable, #available(iOS 26.0, *) {
      // True Apple Liquid Glass (iOS 26+ / WWDC25 API)
      if let glassEffectClass = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
        let effect = glassEffectClass.init()
        let effectView = UIVisualEffectView(effect: effect)
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.layer.cornerRadius = cornerRadius
        effectView.layer.masksToBounds = true
        effectView.isUserInteractionEnabled = false
        container.addSubview(effectView)
      } else {
        setupUIKitVisualEffect(in: container, variant: variant, cornerRadius: cornerRadius, tintColorOverride: tintColorOverride)
      }
    } else {
      setupUIKitVisualEffect(in: container, variant: variant, cornerRadius: cornerRadius, tintColorOverride: tintColorOverride)
    }

    // Specular highlight border
    let specularEdge = UIView()
    specularEdge.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    specularEdge.layer.cornerRadius = cornerRadius
    specularEdge.layer.borderWidth = isSelected ? 1.5 : 0.5
    specularEdge.layer.borderColor = isSelected
      ? UIColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 0.9).cgColor
      : UIColor.white.withAlphaComponent(0.25).cgColor
    specularEdge.isUserInteractionEnabled = false
    container.addSubview(specularEdge)

    return container
  }

  static func setupUIKitVisualEffect(
    in container: UIView,
    variant: String,
    cornerRadius: CGFloat,
    tintColorOverride: UIColor? = nil
  ) {
    let blurEffect: UIBlurEffect
    var tintColor: UIColor? = tintColorOverride

    switch variant {
    case "prominent":
      blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
      if tintColor == nil {
        tintColor = UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 0.35)
      }
    case "clear":
      blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
      if tintColor == nil {
        tintColor = UIColor.white.withAlphaComponent(0.04)
      }
    case "danger":
      blurEffect = UIBlurEffect(style: .systemThinMaterialDark)
      if tintColor == nil {
        tintColor = UIColor(red: 220/255, green: 38/255, blue: 38/255, alpha: 0.28)
      }
    case "regular":
      blurEffect = UIBlurEffect(style: .systemMaterial)
      if tintColor == nil {
        tintColor = UIColor.white.withAlphaComponent(0.12)
      }
    default:
      blurEffect = UIBlurEffect(style: .systemMaterial)
      if tintColor == nil {
        tintColor = UIColor.white.withAlphaComponent(0.12)
      }
    }

    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blurView.layer.cornerRadius = cornerRadius
    blurView.layer.masksToBounds = true
    blurView.isUserInteractionEnabled = false
    container.addSubview(blurView)

    if let tint = tintColor {
      let tintView = UIView()
      tintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      tintView.backgroundColor = tint
      tintView.layer.cornerRadius = cornerRadius
      tintView.layer.masksToBounds = true
      tintView.isUserInteractionEnabled = false
      container.addSubview(tintView)
    }
  }
}

class NativeGlassHostPlatformView: NSObject, FlutterPlatformView {
  private static var activeHosts: [NativeGlassHostPlatformView] = []
  private var containerView: UIView
  private var surfaceViews: [String: UIView] = [:]
  private var groupContainers: [String: UIView] = [:]

  static func setOverlayActive(_ active: Bool) {
    for host in activeHosts {
      host.containerView.isHidden = active
    }
  }

  static func updateSurfaces(_ surfaces: [[String: Any]]) {
    for host in activeHosts {
      host.applySurfaces(surfaces)
    }
  }

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    binaryMessenger: FlutterBinaryMessenger?
  ) {
    containerView = UIView(frame: frame)
    containerView.backgroundColor = .clear
    containerView.isUserInteractionEnabled = false
    super.init()
    NativeGlassHostPlatformView.activeHosts.append(self)

    if let params = args as? [String: Any], let surfaces = params["surfaces"] as? [[String: Any]] {
      applySurfaces(surfaces)
    }
  }

  deinit {
    NativeGlassHostPlatformView.activeHosts.removeAll { $0 === self }
  }

  func view() -> UIView {
    return containerView
  }

  private func applySurfaces(_ surfaces: [[String: Any]]) {
    var seenIds = Set<String>()
    var groupSurfaces: [String: [[String: Any]]] = [:]
    var ungroupedSurfaces: [[String: Any]] = []

    for surf in surfaces {
      guard let id = surf["id"] as? String else { continue }
      seenIds.insert(id)
      if let groupId = surf["groupId"] as? String, !groupId.isEmpty {
        groupSurfaces[groupId, default: []].append(surf)
      } else {
        ungroupedSurfaces.append(surf)
      }
    }

    // 1. Process ungrouped independent surfaces
    for surf in ungroupedSurfaces {
      guard let id = surf["id"] as? String else { continue }
      let x = CGFloat(surf["x"] as? Double ?? 0.0)
      let y = CGFloat(surf["y"] as? Double ?? 0.0)
      let w = CGFloat(surf["w"] as? Double ?? 0.0)
      let h = CGFloat(surf["h"] as? Double ?? 0.0)
      let radius = CGFloat(surf["radius"] as? Double ?? 20.0)
      let variant = surf["variant"] as? String ?? "regular"
      let isSelected = surf["isSelected"] as? Bool ?? false
      let frame = CGRect(x: x, y: y, width: w, height: h)

      var tintColor: UIColor? = nil
      if let tintVal = surf["tint"] as? Int64 {
        let a = CGFloat((tintVal >> 24) & 0xFF) / 255.0
        let r = CGFloat((tintVal >> 16) & 0xFF) / 255.0
        let g = CGFloat((tintVal >> 8) & 0xFF) / 255.0
        let b = CGFloat(tintVal & 0xFF) / 255.0
        tintColor = UIColor(red: r, green: g, blue: b, alpha: a)
      }

      if let existing = surfaceViews[id] {
        existing.frame = frame
      } else {
        let view = NativeGlassPlatformView.createGlassEffectView(
          variant: variant,
          cornerRadius: radius,
          isSelected: isSelected,
          tintColorOverride: tintColor
        )
        view.frame = frame
        containerView.addSubview(view)
        surfaceViews[id] = view
      }
    }

    // 2. Process grouped surfaces (e.g. right-toolbar with UIGlassContainerEffect)
    var seenGroups = Set<String>()
    for (groupId, groupList) in groupSurfaces {
      seenGroups.insert(groupId)

      var minX = CGFloat.infinity, minY = CGFloat.infinity
      var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
      for s in groupList {
        let x = CGFloat(s["x"] as? Double ?? 0.0)
        let y = CGFloat(s["y"] as? Double ?? 0.0)
        let w = CGFloat(s["w"] as? Double ?? 0.0)
        let h = CGFloat(s["h"] as? Double ?? 0.0)
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x + w)
        maxY = max(maxY, y + h)
      }
      let groupFrame = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))

      let groupContainer: UIView
      if let existingGroup = groupContainers[groupId] {
        existingGroup.frame = groupFrame
        groupContainer = existingGroup
      } else {
        groupContainer = NativeGlassPlatformView.createGlassContainerView(cornerRadius: 22.0)
        groupContainer.frame = groupFrame
        containerView.addSubview(groupContainer)
        groupContainers[groupId] = groupContainer
      }

      for s in groupList {
        guard let id = s["id"] as? String else { continue }
        let x = CGFloat(s["x"] as? Double ?? 0.0)
        let y = CGFloat(s["y"] as? Double ?? 0.0)
        let w = CGFloat(s["w"] as? Double ?? 0.0)
        let h = CGFloat(s["h"] as? Double ?? 0.0)
        let radius = CGFloat(s["radius"] as? Double ?? 20.0)
        let variant = s["variant"] as? String ?? "regular"
        let isSelected = s["isSelected"] as? Bool ?? false
        let relFrame = CGRect(x: x - minX, y: y - minY, width: w, height: h)

        if let existing = surfaceViews[id] {
          existing.frame = relFrame
        } else {
          let view = NativeGlassPlatformView.createGlassEffectView(
            variant: variant,
            cornerRadius: radius,
            isSelected: isSelected
          )
          view.frame = relFrame
          if let effectView = groupContainer.subviews.compactMap({ $0 as? UIVisualEffectView }).first {
            effectView.contentView.addSubview(view)
          } else {
            groupContainer.addSubview(view)
          }
          surfaceViews[id] = view
        }
      }
    }

    // 3. Remove stale groups
    for (groupId, groupView) in groupContainers where !seenGroups.contains(groupId) {
      groupView.removeFromSuperview()
      groupContainers.removeValue(forKey: groupId)
    }

    // 4. Remove stale individual surface views
    for (id, view) in surfaceViews where !seenIds.contains(id) {
      view.removeFromSuperview()
      surfaceViews.removeValue(forKey: id)
    }
  }
}
