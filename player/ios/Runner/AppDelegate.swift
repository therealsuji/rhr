import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "RhrSession")!
      .messenger()
    let channel = FlutterMethodChannel(name: "rhr/session", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let svc = RhrSessionService.shared
      switch call.method {
      case "start":
        let a = call.arguments as? [String: Any] ?? [:]
        svc.start(
          relayUrl: a["relayUrl"] as? String ?? "",
          code: a["code"] as? String ?? "",
          vmUri: a["vmUri"] as? String ?? "")
        result(nil)
      case "kick":
        // On iOS the lobby also re-passes the current VM URI here so the
        // service can re-announce after a guest restart (no logcat to watch).
        if let a = call.arguments as? [String: Any], let vm = a["vmUri"] as? String {
          svc.updateVmUri(vm)
        }
        svc.kick()
        result(nil)
      case "stop":
        svc.stop()
        result(nil)
      case "status":
        result(svc.status)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
