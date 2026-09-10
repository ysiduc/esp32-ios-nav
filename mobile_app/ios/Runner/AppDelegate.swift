import Flutter
import UIKit
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CXCallObserverDelegate {
  private var callObserver: CXCallObserver?
  private var callChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as? FlutterViewController
    if let controller = controller {
      callChannel = FlutterMethodChannel(name: "com.esp32nav.app/native_call", binaryMessenger: controller.binaryMessenger)
    }

    callObserver = CXCallObserver()
    callObserver?.setDelegate(self, queue: DispatchQueue.main)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // CXCallObserverDelegate - Detects incoming phone calls in real time
  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    if !call.hasConnected && !call.hasEnded && !call.isOutgoing {
      // Incoming Phone Call ringing on iPhone
      callChannel?.invokeMethod("onIncomingCall", arguments: ["uuid": call.uuid.uuidString])
    } else if call.hasEnded {
      // Call ended / rejected
      callChannel?.invokeMethod("onCallEnded", arguments: ["uuid": call.uuid.uuidString])
    }
  }
}

