import Flutter
import UIKit
import MediaPlayer
import CallKit
import CoreLocation
import MapKit
import AVFoundation
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaChannel: FlutterMethodChannel?
  private var callChannel: FlutterMethodChannel?
  private var locationChannel: FlutterMethodChannel?
  private var isChannelSetup = false
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var zipPickerDelegate: ZipDocumentPickerDelegate?

  // CallKit observer - theo dõi cuộc gọi
  private var callObserver: CXCallObserver?
  private var callObserverDelegate: CallObserverDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UIDevice.current.isBatteryMonitoringEnabled = true
    NotificationCenter.default.addObserver(
      forName: UIDevice.batteryLevelDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.notifyBatteryLevel()
    }
    NotificationCenter.default.addObserver(
      forName: UIDevice.batteryStateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.notifyBatteryLevel()
    }
    if let controller = window?.rootViewController as? FlutterViewController {
      setupChannels(binaryMessenger: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func notifyBatteryLevel() {
    let rawLevel = UIDevice.current.batteryLevel
    if rawLevel >= 0 {
      let percentage = Int(round(rawLevel * 100.0))
      locationChannel?.invokeMethod("onBatteryChanged", arguments: percentage)
    }
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
      case "compressRgbaToJpeg":
        guard let args = call.arguments as? [String: Any],
              let rgbaTyped = args["rgba"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int else {
          result(nil)
          return
        }
        let quality = (args["quality"] as? Double) ?? 0.65
        let data = rgbaTyped.data
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        if let provider = CGDataProvider(data: data as CFData),
           let cgImage = CGImage(
             width: width,
             height: height,
             bitsPerComponent: bitsPerComponent,
             bitsPerPixel: 32,
             bytesPerRow: bytesPerRow,
             space: colorSpace,
             bitmapInfo: bitmapInfo,
             provider: provider,
             decode: nil,
             shouldInterpolate: false,
             intent: .defaultIntent
           ) {
          var finalImage = UIImage(cgImage: cgImage)
          let roadLabels = args["roadLabels"] as? [[String: Any]]
          let isDark = (args["isDark"] as? Bool) ?? false
          if let hud = args["hud"] as? [String: Any] {
            finalImage = Self.drawNavigationHud(
              baseImage: finalImage,
              hud: hud,
              roadLabels: roadLabels,
              isDark: isDark,
              width: CGFloat(width),
              height: CGFloat(height)
            )
          } else if let labels = roadLabels, !labels.isEmpty {
            finalImage = Self.drawRoadLabelsOnImage(
              baseImage: finalImage,
              labels: labels,
              isDark: isDark,
              width: CGFloat(width),
              height: CGFloat(height)
            )
          }
          if let jpegData = finalImage.jpegData(compressionQuality: CGFloat(quality)) {
            result(FlutterStandardTypedData(bytes: jpegData))
            return
          }
        }
        result(nil)
      case "renderMapSnapshot":
        guard let args = call.arguments as? [String: Any],
              let lat = args["lat"] as? Double,
              let lng = args["lng"] as? Double else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing lat/lng", details: nil))
          return
        }
        let width = (args["width"] as? Double) ?? 112.0
        let height = (args["height"] as? Double) ?? 224.0
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
      case "speakGuidance":
        if let args = call.arguments as? [String: Any],
           let text = args["text"] as? String {
          NavigationSpeechSynthesizer.shared.speak(text)
        } else if let text = call.arguments as? String {
          NavigationSpeechSynthesizer.shared.speak(text)
        }
        result(true)
      case "stopGuidance":
        NavigationSpeechSynthesizer.shared.stop()
        result(true)
      case "pickZipFile":
        DispatchQueue.main.async {
          guard let presenter = self?.topPresentingViewController() else {
            result(FlutterError(code: "NO_UI", message: "No rootViewController", details: nil))
            return
          }
          let delegate = ZipDocumentPickerDelegate { [weak self] payload in
            self?.zipPickerDelegate = nil
            result(payload)
          }
          self?.zipPickerDelegate = delegate
          let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.zip], asCopy: true)
          picker.delegate = delegate
          picker.allowsMultipleSelection = false
          presenter.present(picker, animated: true, completion: nil)
        }
      case "shareFileBytes":
        guard let args = call.arguments as? [String: Any],
              let typed = args["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing bytes", details: nil))
          return
        }
        let rawName = (args["fileName"] as? String) ?? "esp32_theme_template.zip"
        let safeName = URL(fileURLWithPath: rawName).lastPathComponent
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
          try typed.data.write(to: tempUrl, options: .atomic)
          DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: [tempUrl], applicationActivities: nil)
            let rootVC = self?.topPresentingViewController()
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ─── 4. Apple Maps Native Channel (MKLocalSearch & MKDirections) ──────
    AppleMapsService.shared.setup(binaryMessenger: binaryMessenger)

    // Khởi động CallKit observer
    setupCallObserver()
  }

  private func topPresentingViewController() -> UIViewController? {
    var top = self.window?.rootViewController ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? UIApplication.shared.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
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

  // ─── Pure-CPU CoreGraphics Street Labels & HUD Renderer (Works 100% in Background & Foreground) ───
  static func drawRoadLabelsOnImage(
    baseImage: UIImage,
    labels: [[String: Any]],
    isDark: Bool,
    width: CGFloat,
    height: CGFloat
  ) -> UIImage {
    let size = CGSize(width: width, height: height)
    UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
    defer { UIGraphicsEndImageContext() }
    guard let ctx = UIGraphicsGetCurrentContext() else { return baseImage }
    baseImage.draw(in: CGRect(origin: .zero, size: size))
    drawRoadLabels(in: ctx, labels: labels, isDark: isDark)
    return UIGraphicsGetImageFromCurrentImageContext() ?? baseImage
  }

  static func drawRoadLabels(
    in ctx: CGContext,
    labels: [[String: Any]],
    isDark: Bool
  ) {
    let textColor = isDark
      ? UIColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1.0)
      : UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 1.0)
    let haloColor = isDark
      ? UIColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 0.96)
      : UIColor(white: 1.0, alpha: 0.98)

    for item in labels {
      guard let rawText = item["text"] as? String, !rawText.isEmpty,
            let sx = (item["sx"] as? NSNumber)?.doubleValue,
            let sy = (item["sy"] as? NSNumber)?.doubleValue else {
        continue
      }
      let angleDeg = (item["angleDeg"] as? NSNumber)?.doubleValue ?? 0.0
      let tier = (item["tier"] as? NSNumber)?.intValue ?? 1
      let text = rawText.precomposedStringWithCanonicalMapping as NSString
      let fontSize: CGFloat = tier >= 3 ? 10.0 : 8.8
      let weight: UIFont.Weight = tier >= 3 ? .bold : .semibold
      let font = UIFont.systemFont(ofSize: fontSize, weight: weight)

      let haloAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: haloColor,
        .strokeColor: haloColor,
        .strokeWidth: 3.5
      ]
      let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor
      ]

      let textSize = text.size(withAttributes: textAttrs)
      let drawRect = CGRect(
        x: -textSize.width / 2.0,
        y: -textSize.height / 2.0,
        width: textSize.width,
        height: textSize.height
      )

      ctx.saveGState()
      ctx.translateBy(x: CGFloat(sx), y: CGFloat(sy))
      ctx.rotate(by: CGFloat(angleDeg * Double.pi / 180.0))
      text.draw(in: drawRect, withAttributes: haloAttrs)
      text.draw(in: drawRect, withAttributes: textAttrs)
      ctx.restoreGState()
    }
  }

  static func drawNavigationHud(
    baseImage: UIImage,
    hud: [String: Any],
    roadLabels: [[String: Any]]? = nil,
    isDark: Bool = false,
    width: CGFloat,
    height: CGFloat
  ) -> UIImage {
    let size = CGSize(width: width, height: height)
    UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
    defer { UIGraphicsEndImageContext() }
    guard let ctx = UIGraphicsGetCurrentContext() else { return baseImage }

    baseImage.draw(in: CGRect(origin: .zero, size: size))
    if let labels = roadLabels, !labels.isEmpty {
      drawRoadLabels(in: ctx, labels: labels, isDark: isDark)
    }

    let vx = CGFloat((hud["vx"] as? Double) ?? 174.0)
    let vy = CGFloat((hud["vy"] as? Double) ?? (Double(height) * 0.73)) // ~158 on h=216
    let curRoad = ((hud["curRoad"] as? String) ?? "Đường hiện tại").precomposedStringWithCanonicalMapping
    let nextStreet = ((hud["nextStreet"] as? String) ?? "Đi thẳng").precomposedStringWithCanonicalMapping
    let distStr = (hud["distStr"] as? String) ?? "0 m"
    let turnCode = (hud["turnCode"] as? Int) ?? 0
    let speedStr = (hud["speedStr"] as? String) ?? "0"
    let etaText = ((hud["etaText"] as? String) ?? "1 phút").precomposedStringWithCanonicalMapping
    let subText = ((hud["subText"] as? String) ?? "00:00 • 0 km").precomposedStringWithCanonicalMapping
    let speedLimit = (hud["speedLimit"] as? Int) ?? 50
    let isOverSpeed = (hud["isOverSpeed"] as? Bool) ?? false
    let hazardType = (hud["hazardType"] as? String) ?? ""
    let hazardDistM = (hud["hazardDistM"] as? Int) ?? -1

    // 1. Google Maps 3D Vehicle Puck (Soft blue aura + white disc + cobalt arrow)
    ctx.saveGState()
    UIColor(red: 0.102, green: 0.451, blue: 0.910, alpha: 0.22).setFill()
    ctx.fillEllipse(in: CGRect(x: vx - 14.5, y: vy - 14.5, width: 29.0, height: 29.0))

    UIColor(red: 0.420, green: 0.540, blue: 0.720, alpha: 0.35).setFill()
    ctx.fillEllipse(in: CGRect(x: vx - 10.8, y: vy - 10.3, width: 21.6, height: 21.6))

    UIColor.white.setFill()
    ctx.fillEllipse(in: CGRect(x: vx - 10.0, y: vy - 10.0, width: 20.0, height: 20.0))

    let puckArrow = UIBezierPath()
    puckArrow.move(to: CGPoint(x: vx, y: vy - 5.8))
    puckArrow.addLine(to: CGPoint(x: vx + 4.8, y: vy + 4.8))
    puckArrow.addLine(to: CGPoint(x: vx, y: vy + 1.8))
    puckArrow.addLine(to: CGPoint(x: vx - 4.8, y: vy + 4.8))
    puckArrow.close()
    UIColor(red: 0.102, green: 0.451, blue: 0.910, alpha: 1.0).setFill()
    puckArrow.fill()
    ctx.restoreGState()

    // 2. Bottom-Right Current Street Pill (Blue pill matching iPhone UI)
    let roadParagraph = NSMutableParagraphStyle()
    roadParagraph.alignment = .center
    roadParagraph.lineBreakMode = .byTruncatingTail
    let roadAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 9.5, weight: .heavy),
      .foregroundColor: UIColor.white,
      .paragraphStyle: roadParagraph
    ]
    let roadNs = curRoad as NSString
    let roadBox = roadNs.boundingRect(
      with: CGSize(width: 104.0, height: 26.0),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: roadAttrs,
      context: nil
    )
    let pillW = min(max(ceil(roadBox.width) + 14.0, 72.0), 118.0)
    let pillH = min(max(ceil(roadBox.height) + 6.0, 20.0), 28.0)
    let pillLeft = min(max(vx - pillW / 2.0, 118.0), width - pillW - 4.0)
    let pillTop = min(max(vy + 13.0, 170.0), height - pillH - 4.0)
    let pillRect = CGRect(x: pillLeft, y: pillTop, width: pillW, height: pillH)
    let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 10.0)
    UIColor(red: 0.114, green: 0.388, blue: 1.0, alpha: 1.0).setFill()
    pillPath.fill()
    UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1.0).setStroke()
    pillPath.lineWidth = 1.2
    pillPath.stroke()
    let roadDrawRect = CGRect(
      x: pillLeft + 5.0,
      y: pillTop + (pillH - ceil(roadBox.height)) / 2.0,
      width: pillW - 10.0,
      height: ceil(roadBox.height) + 2.0
    )
    roadNs.draw(in: roadDrawRect, withAttributes: roadAttrs)

    // 3. Top-Left Compact Black Maneuver Card + Coral-Red Top Badge (240x216)
    let blackCardRect = CGRect(x: 4.0, y: 4.0, width: 104.0, height: 48.0)
    let blackCardShadow = UIBezierPath(roundedRect: blackCardRect.offsetBy(dx: 0, dy: 2), cornerRadius: 10.0)
    UIColor(white: 0.0, alpha: 0.30).setFill()
    blackCardShadow.fill()

    let blackCardPath = UIBezierPath(roundedRect: blackCardRect, cornerRadius: 10.0)
    UIColor(red: 0.035, green: 0.039, blue: 0.059, alpha: 0.96).setFill()
    blackCardPath.fill()
    UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1.0).setStroke()
    blackCardPath.lineWidth = 1.0
    blackCardPath.stroke()

    let coralRect = CGRect(x: 2.0, y: 2.0, width: 70.0, height: 21.0)
    let coralPath = UIBezierPath(roundedRect: coralRect, cornerRadius: 10.0)
    UIColor(red: 0.941, green: 0.384, blue: 0.380, alpha: 1.0).setFill()
    coralPath.fill()
    let coralInner = UIBezierPath(roundedRect: coralRect.insetBy(dx: 1.0, dy: 1.0), cornerRadius: 9.0)
    UIColor(white: 1.0, alpha: 0.85).setStroke()
    coralInner.lineWidth = 1.0
    coralInner.stroke()

    drawTurnArrow(ctx: ctx, cx: 13.0, cy: 12.5, turnCode: turnCode)

    let distAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 11.0, weight: .heavy),
      .foregroundColor: UIColor.white
    ]
    let distNs = distStr as NSString
    let distSize = distNs.size(withAttributes: distAttrs)
    distNs.draw(
      at: CGPoint(x: 23.0, y: 2.0 + (21.0 - distSize.height) / 2.0),
      withAttributes: distAttrs
    )

    let streetAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 10.5, weight: .bold),
      .foregroundColor: UIColor(red: 0.973, green: 0.980, blue: 0.988, alpha: 1.0)
    ]
    let streetNs = (nextStreet.isEmpty ? "Đi thẳng" : nextStreet) as NSString
    let streetSize = streetNs.size(withAttributes: streetAttrs)
    let textW = ceil(streetSize.width)
    let availW: CGFloat = 92.0

    if textW > availW {
      let loopDist = textW + 32.0
      let nowMs = Int(Date().timeIntervalSince1970 * 1000)
      let cycleMs = Int(loopDist * 35.0)
      let totalCycle = cycleMs + 2000
      let phaseMs = nowMs % totalCycle
      let scrollX: CGFloat = (phaseMs < 1200)
        ? 0.0
        : (phaseMs > cycleMs + 1200)
            ? 0.0
            : CGFloat(phaseMs - 1200) / 35.0

      ctx.saveGState()
      let clipRect = CGRect(x: 6.0, y: 24.0, width: availW + 4.0, height: 22.0)
      ctx.clip(to: clipRect)
      let off = scrollX.truncatingRemainder(dividingBy: loopDist)
      streetNs.draw(at: CGPoint(x: 8.0 - off, y: 26.0), withAttributes: streetAttrs)
      streetNs.draw(at: CGPoint(x: 8.0 - off + loopDist, y: 26.0), withAttributes: streetAttrs)
      ctx.restoreGState()
    } else {
      streetNs.draw(at: CGPoint(x: 8.0, y: 26.0), withAttributes: streetAttrs)
    }

    // 4. Speedometer Box (nhấp nháy Đỏ khi quá tốc độ) + Biển báo tốc độ viền đỏ + Huy hiệu Camera phạt nguội
    let flashRedOn = isOverSpeed && ((Int(Date().timeIntervalSince1970 * 1000) / 400) % 2 == 0)
    let speedRect = CGRect(x: 4.0, y: 118.0, width: 42.0, height: 36.0)
    let speedPath = UIBezierPath(roundedRect: speedRect, cornerRadius: 10.0)
    if isOverSpeed {
      (flashRedOn
        ? UIColor(red: 0.863, green: 0.149, blue: 0.149, alpha: 0.97)
        : UIColor(red: 0.600, green: 0.106, blue: 0.106, alpha: 0.97)
      ).setFill()
    } else {
      UIColor(red: 0.094, green: 0.098, blue: 0.118, alpha: 0.95).setFill()
    }
    speedPath.fill()
    if isOverSpeed {
      (flashRedOn
        ? UIColor(red: 0.988, green: 0.647, blue: 0.647, alpha: 1.0)
        : UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1.0)
      ).setStroke()
      speedPath.lineWidth = 2.0
    } else {
      UIColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.90).setStroke()
      speedPath.lineWidth = 1.4
    }
    speedPath.stroke()

    let spdNumAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 14.5, weight: .black),
      .foregroundColor: UIColor.white
    ]
    let spdNs = speedStr as NSString
    let spdSize = spdNs.size(withAttributes: spdNumAttrs)
    spdNs.draw(
      at: CGPoint(x: 4.0 + (42.0 - spdSize.width) / 2.0, y: 120.0),
      withAttributes: spdNumAttrs
    )

    let unitAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 8.0, weight: .bold),
      .foregroundColor: isOverSpeed
        ? UIColor(red: 0.996, green: 0.886, blue: 0.886, alpha: 1.0)
        : UIColor(red: 0.580, green: 0.639, blue: 0.722, alpha: 1.0)
    ]
    let unitNs = "km/h" as NSString
    let unitSize = unitNs.size(withAttributes: unitAttrs)
    unitNs.draw(
      at: CGPoint(x: 4.0 + (42.0 - unitSize.width) / 2.0, y: 139.0),
      withAttributes: unitAttrs
    )

    // 4b. Biển báo tốc độ giới hạn viền đỏ động (cx: 64, cy: 136, r: 14.5)
    let limCx: CGFloat = 64.0
    let limCy: CGFloat = 136.0
    UIColor(white: 0.0, alpha: 0.35).setFill()
    ctx.fillEllipse(in: CGRect(x: limCx - 15.5, y: limCy - 15.0, width: 31.0, height: 31.0))
    UIColor.white.setFill()
    ctx.fillEllipse(in: CGRect(x: limCx - 14.5, y: limCy - 14.5, width: 29.0, height: 29.0))
    let limRing = UIBezierPath(ovalIn: CGRect(x: limCx - 12.8, y: limCy - 12.8, width: 25.6, height: 25.6))
    UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1.0).setStroke()
    limRing.lineWidth = 3.2
    limRing.stroke()

    let limAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: speedLimit >= 100 ? 9.5 : 11.5, weight: .black),
      .foregroundColor: UIColor(red: 0.067, green: 0.094, blue: 0.153, alpha: 1.0)
    ]
    let limNs = "\(speedLimit)" as NSString
    let limSize = limNs.size(withAttributes: limAttrs)
    limNs.draw(
      at: CGPoint(x: limCx - limSize.width / 2.0, y: limCy - limSize.height / 2.0),
      withAttributes: limAttrs
    )

    // 4c. Huy hiệu Camera phạt nguội / Biển báo kèm khoảng cách đếm ngược (< 300m)
    if !hazardType.isEmpty && hazardDistM >= 0 && hazardDistM < 300 {
      let isCam = (hazardType == "speed_camera")
      let camRect = CGRect(x: 83.0, y: 120.0, width: 36.0, height: 32.0)
      let camPath = UIBezierPath(roundedRect: camRect, cornerRadius: 8.0)
      (isCam
        ? UIColor(red: 0.725, green: 0.110, blue: 0.110, alpha: 0.96)
        : UIColor(red: 0.851, green: 0.467, blue: 0.024, alpha: 0.96)
      ).setFill()
      camPath.fill()
      UIColor(white: 1.0, alpha: 0.86).setStroke()
      camPath.lineWidth = 1.1
      camPath.stroke()

      if isCam {
        let bodyPath = UIBezierPath(roundedRect: CGRect(x: 94.0, y: 124.0, width: 14.0, height: 9.0), cornerRadius: 2.0)
        UIColor.white.setFill()
        bodyPath.fill()
        UIColor(red: 0.725, green: 0.110, blue: 0.110, alpha: 1.0).setFill()
        ctx.fillEllipse(in: CGRect(x: 98.4, y: 125.9, width: 5.2, height: 5.2))
        UIColor(red: 0.992, green: 0.878, blue: 0.278, alpha: 1.0).setFill()
        ctx.fillEllipse(in: CGRect(x: 99.9, y: 127.4, width: 2.2, height: 2.2))
      } else {
        let tri = UIBezierPath()
        tri.move(to: CGPoint(x: 101.0, y: 123.5))
        tri.addLine(to: CGPoint(x: 107.0, y: 134.0))
        tri.addLine(to: CGPoint(x: 95.0, y: 134.0))
        tri.close()
        UIColor.white.setFill()
        tri.fill()
      }

      let camDistAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 9.0, weight: .black),
        .foregroundColor: UIColor.white
      ]
      let camDistNs = "\(hazardDistM)m" as NSString
      let camDistSize = camDistNs.size(withAttributes: camDistAttrs)
      camDistNs.draw(
        at: CGPoint(x: 83.0 + (36.0 - camDistSize.width) / 2.0, y: 138.0),
        withAttributes: camDistAttrs
      )
    }

    // 5. Compact Bottom-Left Dark Trip Summary Card (x: 4, y: 162, w: 110, h: 44)
    let summaryRect = CGRect(x: 4.0, y: 162.0, width: 110.0, height: 44.0)
    let summaryPath = UIBezierPath(roundedRect: summaryRect, cornerRadius: 11.0)
    UIColor(red: 0.118, green: 0.125, blue: 0.145, alpha: 0.96).setFill()
    summaryPath.fill()
    UIColor(red: 0.247, green: 0.247, blue: 0.275, alpha: 1.0).setStroke()
    summaryPath.lineWidth = 1.0
    summaryPath.stroke()

    // Left '✕' circle at (17, 184), r=9
    UIColor(red: 0.220, green: 0.224, blue: 0.243, alpha: 1.0).setFill()
    ctx.fillEllipse(in: CGRect(x: 17.0 - 9.0, y: 184.0 - 9.0, width: 18.0, height: 18.0))
    ctx.saveGState()
    ctx.setStrokeColor(UIColor.white.cgColor)
    ctx.setLineWidth(1.8)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 14.0, y: 181.0))
    ctx.addLine(to: CGPoint(x: 20.0, y: 187.0))
    ctx.move(to: CGPoint(x: 20.0, y: 181.0))
    ctx.addLine(to: CGPoint(x: 14.0, y: 187.0))
    ctx.strokePath()
    ctx.restoreGState()

    let etaAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 11.0, weight: .heavy),
      .foregroundColor: UIColor.white
    ]
    (etaText as NSString).draw(
      in: CGRect(x: 30.0, y: 167.0, width: 80.0, height: 16.0),
      withAttributes: etaAttrs
    )

    let subAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 9.0, weight: .semibold),
      .foregroundColor: UIColor(red: 0.894, green: 0.894, blue: 0.906, alpha: 1.0)
    ]
    (subText as NSString).draw(
      in: CGRect(x: 30.0, y: 185.0, width: 80.0, height: 15.0),
      withAttributes: subAttrs
    )

    return UIGraphicsGetImageFromCurrentImageContext() ?? baseImage
  }

  static func drawTurnArrow(ctx: CGContext, cx: CGFloat, cy: CGFloat, turnCode: Int) {
    ctx.saveGState()
    ctx.setStrokeColor(UIColor.white.cgColor)
    ctx.setFillColor(UIColor.white.cgColor)
    ctx.setLineWidth(2.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    if turnCode == 5 || turnCode == 6 || turnCode == 7 {
      // Turn Left
      ctx.move(to: CGPoint(x: cx + 3.5, y: cy + 4.5))
      ctx.addLine(to: CGPoint(x: cx + 3.5, y: cy - 1.5))
      ctx.addLine(to: CGPoint(x: cx - 3.0, y: cy - 1.5))
      ctx.strokePath()

      ctx.move(to: CGPoint(x: cx - 5.5, y: cy - 1.5))
      ctx.addLine(to: CGPoint(x: cx - 1.5, y: cy - 5.0))
      ctx.addLine(to: CGPoint(x: cx - 1.5, y: cy + 2.0))
      ctx.closePath()
      ctx.fillPath()
    } else if turnCode == 1 || turnCode == 2 || turnCode == 3 {
      // Turn Right
      ctx.move(to: CGPoint(x: cx - 3.5, y: cy + 4.5))
      ctx.addLine(to: CGPoint(x: cx - 3.5, y: cy - 1.5))
      ctx.addLine(to: CGPoint(x: cx + 3.0, y: cy - 1.5))
      ctx.strokePath()

      ctx.move(to: CGPoint(x: cx + 5.5, y: cy - 1.5))
      ctx.addLine(to: CGPoint(x: cx + 1.5, y: cy - 5.0))
      ctx.addLine(to: CGPoint(x: cx + 1.5, y: cy + 2.0))
      ctx.closePath()
      ctx.fillPath()
    } else if turnCode == 4 {
      // U-Turn
      ctx.move(to: CGPoint(x: cx + 3.5, y: cy + 4.5))
      ctx.addLine(to: CGPoint(x: cx + 3.5, y: cy - 2.0))
      ctx.addArc(center: CGPoint(x: cx, y: cy - 2.0), radius: 3.5, startAngle: 0, endAngle: .pi, clockwise: true)
      ctx.addLine(to: CGPoint(x: cx - 3.5, y: cy + 2.0))
      ctx.strokePath()

      ctx.move(to: CGPoint(x: cx - 3.5, y: cy + 5.0))
      ctx.addLine(to: CGPoint(x: cx - 6.5, y: cy + 1.5))
      ctx.addLine(to: CGPoint(x: cx - 0.5, y: cy + 1.5))
      ctx.closePath()
      ctx.fillPath()
    } else {
      // Straight Ahead
      ctx.move(to: CGPoint(x: cx, y: cy + 5.0))
      ctx.addLine(to: CGPoint(x: cx, y: cy - 2.5))
      ctx.strokePath()

      ctx.move(to: CGPoint(x: cx, y: cy - 5.5))
      ctx.addLine(to: CGPoint(x: cx - 3.8, y: cy - 1.0))
      ctx.addLine(to: CGPoint(x: cx + 3.8, y: cy - 1.0))
      ctx.closePath()
      ctx.fillPath()
    }
    ctx.restoreGState()
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
        let title = ((dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? "").precomposedStringWithCanonicalMapping
        let artist = ((dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? "").precomposedStringWithCanonicalMapping
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
    width: Double = 112.0,
    height: Double = 224.0,
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
      let jpegData = image.jpegData(compressionQuality: 0.80)
      completion(jpegData)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NavigationSpeechSynthesizer (Native iOS Vietnamese Voice Guidance)
// ─────────────────────────────────────────────────────────────────────────────
final class NavigationSpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = NavigationSpeechSynthesizer()
  private let synthesizer = AVSpeechSynthesizer()

  private override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try session.setActive(true)
      } catch {}

      if self.synthesizer.isSpeaking {
        self.synthesizer.stopSpeaking(at: .immediate)
      }

      guard let viVoice = AVSpeechSynthesisVoice(language: "vi-VN")
        ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.lowercased().hasPrefix("vi") }) else {
        // Never fall back to en-US, which reads Vietnamese phonetically in English.
        return
      }
      let utterance = AVSpeechUtterance(string: trimmed)
      utterance.voice = viVoice
      utterance.rate = 0.51
      utterance.pitchMultiplier = 1.0
      utterance.volume = 1.0
      self.synthesizer.speak(utterance)
    }
  }

  func stop() {
    DispatchQueue.main.async {
      if self.synthesizer.isSpeaking {
        self.synthesizer.stopSpeaking(at: .immediate)
      }
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {}
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {}
  }
}

class ZipDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private var onFinish: (Any?) -> Void
  private var completed = false

  init(onFinish: @escaping (Any?) -> Void) {
    self.onFinish = onFinish
    super.init()
  }

  private func finish(_ value: Any?) {
    guard !completed else { return }
    completed = true
    onFinish(value)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      finish(nil)
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try Data(contentsOf: url)
      finish([
        "name": url.lastPathComponent,
        "bytes": FlutterStandardTypedData(bytes: data)
      ])
    } catch {
      finish(FlutterError(code: "READ_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }
}


