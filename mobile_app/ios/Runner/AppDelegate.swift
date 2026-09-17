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

