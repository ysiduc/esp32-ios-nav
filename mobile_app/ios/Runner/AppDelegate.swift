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
          if let hud = args["hud"] as? [String: Any] {
            finalImage = Self.drawNavigationHud(
              baseImage: finalImage,
              hud: hud,
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

  // ─── Pure-CPU CoreGraphics HUD Renderer (Works 100% in Background & Foreground) ───
  static func drawNavigationHud(
    baseImage: UIImage,
    hud: [String: Any],
    width: CGFloat,
    height: CGFloat
  ) -> UIImage {
    let size = CGSize(width: width, height: height)
    UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
    defer { UIGraphicsEndImageContext() }
    guard let ctx = UIGraphicsGetCurrentContext() else { return baseImage }

    baseImage.draw(in: CGRect(origin: .zero, size: size))

    let vx = CGFloat((hud["vx"] as? Double) ?? 226.0)
    let vy = CGFloat((hud["vy"] as? Double) ?? 182.0)
    let curRoad = (hud["curRoad"] as? String) ?? "Đường hiện tại"
    let nextStreet = (hud["nextStreet"] as? String) ?? "Đi thẳng"
    let distStr = (hud["distStr"] as? String) ?? "0 m"
    let turnCode = (hud["turnCode"] as? Int) ?? 0
    let speedStr = (hud["speedStr"] as? String) ?? "0"
    let etaText = (hud["etaText"] as? String) ?? "1 phút"
    let subText = (hud["subText"] as? String) ?? "00:00 • 0 km"

    // 1. Vehicle 3D Chevron at (vx, vy)
    ctx.saveGState()
    UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 0.28).setFill()
    ctx.fillEllipse(in: CGRect(x: vx - 15.0, y: vy - 14.0, width: 30.0, height: 30.0))

    let leftWing = UIBezierPath()
    leftWing.move(to: CGPoint(x: vx, y: vy - 12.0))
    leftWing.addLine(to: CGPoint(x: vx, y: vy + 3.0))
    leftWing.addLine(to: CGPoint(x: vx - 10.5, y: vy + 7.5))
    leftWing.close()
    UIColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 1.0).setFill()
    leftWing.fill()

    let rightWing = UIBezierPath()
    rightWing.move(to: CGPoint(x: vx, y: vy - 12.0))
    rightWing.addLine(to: CGPoint(x: vx + 10.5, y: vy + 7.5))
    rightWing.addLine(to: CGPoint(x: vx, y: vy + 3.0))
    rightWing.close()
    UIColor(red: 0.008, green: 0.518, blue: 0.780, alpha: 1.0).setFill()
    rightWing.fill()

    let fullChevron = UIBezierPath()
    fullChevron.move(to: CGPoint(x: vx, y: vy - 12.0))
    fullChevron.addLine(to: CGPoint(x: vx + 10.5, y: vy + 7.5))
    fullChevron.addLine(to: CGPoint(x: vx, y: vy + 3.0))
    fullChevron.addLine(to: CGPoint(x: vx - 10.5, y: vy + 7.5))
    fullChevron.close()
    fullChevron.lineJoinStyle = .round
    fullChevron.lineWidth = 2.0
    UIColor.white.setStroke()
    fullChevron.stroke()
    ctx.restoreGState()

    // 2. Bottom-Right Current Street Pill (Blue pill matching iPhone UI)
    let roadParagraph = NSMutableParagraphStyle()
    roadParagraph.alignment = .center
    roadParagraph.lineBreakMode = .byTruncatingTail
    let roadAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 10.5, weight: .heavy),
      .foregroundColor: UIColor.white,
      .paragraphStyle: roadParagraph
    ]
    let roadNs = curRoad as NSString
    let roadBox = roadNs.boundingRect(
      with: CGSize(width: 136.0, height: 28.0),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: roadAttrs,
      context: nil
    )
    let pillW = min(max(ceil(roadBox.width) + 18.0, 78.0), 152.0)
    let pillH = min(max(ceil(roadBox.height) + 8.0, 22.0), 34.0)
    let pillLeft = min(max(vx - pillW / 2.0, 150.0), width - pillW - 4.0)
    let pillTop = min(max(vy + 13.0, 195.0), height - pillH - 3.0)
    let pillRect = CGRect(x: pillLeft, y: pillTop, width: pillW, height: pillH)
    let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 11.0)
    UIColor(red: 0.114, green: 0.388, blue: 1.0, alpha: 1.0).setFill()
    pillPath.fill()
    UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1.0).setStroke()
    pillPath.lineWidth = 1.2
    pillPath.stroke()
    let roadDrawRect = CGRect(
      x: pillLeft + 6.0,
      y: pillTop + (pillH - ceil(roadBox.height)) / 2.0,
      width: pillW - 12.0,
      height: ceil(roadBox.height) + 2.0
    )
    roadNs.draw(in: roadDrawRect, withAttributes: roadAttrs)

    // 3. Top-Left Enlarged Black Maneuver Card + Coral-Red Top Badge
    let blackCardRect = CGRect(x: 4.0, y: 5.0, width: 134.0, height: 48.0)
    let blackCardShadow = UIBezierPath(roundedRect: blackCardRect.offsetBy(dx: 0, dy: 2), cornerRadius: 12.0)
    UIColor(white: 0.0, alpha: 0.30).setFill()
    blackCardShadow.fill()

    let blackCardPath = UIBezierPath(roundedRect: blackCardRect, cornerRadius: 10.0)
    UIColor(red: 0.035, green: 0.039, blue: 0.059, alpha: 0.96).setFill()
    blackCardPath.fill()
    UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1.0).setStroke()
    blackCardPath.lineWidth = 1.0
    blackCardPath.stroke()

    let coralRect = CGRect(x: 0.0, y: 1.0, width: 80.0, height: 20.0)
    let coralPath = UIBezierPath(roundedRect: coralRect, cornerRadius: 9.0)
    UIColor(red: 0.941, green: 0.384, blue: 0.380, alpha: 1.0).setFill()
    coralPath.fill()
    let coralInner = UIBezierPath(roundedRect: coralRect.insetBy(dx: 1.2, dy: 1.2), cornerRadius: 10.0)
    UIColor(white: 1.0, alpha: 0.85).setStroke()
    coralInner.lineWidth = 1.0
    coralInner.stroke()

    drawTurnArrow(ctx: ctx, cx: 14.0, cy: 11.0, turnCode: turnCode)

    let distAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 12.0, weight: .heavy),
      .foregroundColor: UIColor.white
    ]
    let distNs = distStr as NSString
    let distSize = distNs.size(withAttributes: distAttrs)
    distNs.draw(
      at: CGPoint(x: 25.0, y: 1.0 + (20.0 - distSize.height) / 2.0),
      withAttributes: distAttrs
    )

    let streetParagraph = NSMutableParagraphStyle()
    streetParagraph.lineBreakMode = .byTruncatingTail
    streetParagraph.maximumLineHeight = 13.5
    let streetAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 11.5, weight: .bold),
      .foregroundColor: UIColor(red: 0.973, green: 0.980, blue: 0.988, alpha: 1.0),
      .paragraphStyle: streetParagraph
    ]
    let streetNs = (nextStreet.isEmpty ? "Đi thẳng" : nextStreet) as NSString
    streetNs.draw(
      in: CGRect(x: 9.0, y: 24.0, width: 122.0, height: 26.0),
      withAttributes: streetAttrs
    )

    // 4. Speedometer Box placed above Bottom-Left Time Card (x: 4, y: 136, w: 62, h: 46)
    let speedRect = CGRect(x: 4.0, y: 150.0, width: 54.0, height: 38.0)
    let speedPath = UIBezierPath(roundedRect: speedRect, cornerRadius: 12.0)
    UIColor(red: 0.094, green: 0.098, blue: 0.118, alpha: 0.95).setFill()
    speedPath.fill()
    UIColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.90).setStroke()
    speedPath.lineWidth = 1.4
    speedPath.stroke()

    let spdNumAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 17.0, weight: .black),
      .foregroundColor: UIColor.white
    ]
    let spdNs = speedStr as NSString
    let spdSize = spdNs.size(withAttributes: spdNumAttrs)
    spdNs.draw(
      at: CGPoint(x: 4.0 + (54.0 - spdSize.width) / 2.0, y: 152.0),
      withAttributes: spdNumAttrs
    )

    let unitAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 9.5, weight: .bold),
      .foregroundColor: UIColor(red: 0.580, green: 0.639, blue: 0.722, alpha: 1.0)
    ]
    let unitNs = "km/h" as NSString
    let unitSize = unitNs.size(withAttributes: unitAttrs)
    unitNs.draw(
      at: CGPoint(x: 4.0 + (54.0 - unitSize.width) / 2.0, y: 172.0),
      withAttributes: unitAttrs
    )

    // 5. Enlarged Bottom-Left Dark Trip Summary Card (x: 4, y: 186, w: 144, h: 50)
    let summaryRect = CGRect(x: 4.0, y: 192.0, width: 124.0, height: 42.0)
    let summaryPath = UIBezierPath(roundedRect: summaryRect, cornerRadius: 12.0)
    UIColor(red: 0.118, green: 0.125, blue: 0.145, alpha: 0.96).setFill()
    summaryPath.fill()
    UIColor(red: 0.247, green: 0.247, blue: 0.275, alpha: 1.0).setStroke()
    summaryPath.lineWidth = 1.0
    summaryPath.stroke()

    // Left '✕' circle at (21, 211), r=12
    UIColor(red: 0.220, green: 0.224, blue: 0.243, alpha: 1.0).setFill()
    ctx.fillEllipse(in: CGRect(x: 19.0 - 10.0, y: 213.0 - 10.0, width: 20.0, height: 20.0))
    ctx.saveGState()
    ctx.setStrokeColor(UIColor.white.cgColor)
    ctx.setLineWidth(2.0)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 15.7, y: 209.7))
    ctx.addLine(to: CGPoint(x: 22.3, y: 216.3))
    ctx.move(to: CGPoint(x: 22.3, y: 209.7))
    ctx.addLine(to: CGPoint(x: 15.7, y: 216.3))
    ctx.strokePath()
    ctx.restoreGState()

    let etaAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 13.5, weight: .heavy),
      .foregroundColor: UIColor.white
    ]
    (etaText as NSString).draw(
      in: CGRect(x: 34.0, y: 196.0, width: 92.0, height: 18.0),
      withAttributes: etaAttrs
    )

    let subAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 11.0, weight: .semibold),
      .foregroundColor: UIColor(red: 0.894, green: 0.894, blue: 0.906, alpha: 1.0)
    ]
    (subText as NSString).draw(
      in: CGRect(x: 34.0, y: 214.0, width: 92.0, height: 16.0),
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

