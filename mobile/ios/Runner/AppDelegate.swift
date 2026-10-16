import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var liveActivity: LiveActivityBridge?
  private var eventKit: EventKitBridge?
  private var deviceChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EchoLiveActivity") {
      liveActivity = LiveActivityBridge(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EchoEventKit") {
      eventKit = EventKitBridge(messenger: registrar.messenger())
    }
    // "echo/device": the model identifier ("iPhone16,1"), named in phone_name.dart
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EchoDevice") {
      let channel = FlutterMethodChannel(name: "echo/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "model" else {
          result(FlutterMethodNotImplemented)
          return
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
          String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        result(machine)
      }
      deviceChannel = channel
    }
  }
}
