import Flutter
import UIKit
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaChannel: FlutterMethodChannel?
  private var isChannelSetup = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      setupMediaChannel(binaryMessenger: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaPlugin") {
      setupMediaChannel(binaryMessenger: registrar.messenger())
    }
  }

  private func setupMediaChannel(binaryMessenger: FlutterBinaryMessenger) {
    guard !isChannelSetup else { return }
    isChannelSetup = true

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

    // Set up listeners for lock-screen / now-playing changes
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
  }

  private func fetchCurrentNowPlaying(completion: @escaping ([String: Any]) -> Void) {
    MediaRemoteObserver.shared.fetchNowPlaying(completion: completion)
  }
}

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
