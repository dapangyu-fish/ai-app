import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  // 给 Flutter 端发推送 token 用的 channel
  private static let pushChannelName = "dapangyu.fish.myapp/push"
  private weak var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 注册 UNUserNotificationCenter delegate（前台收到通知时也能弹）
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 建立 push MethodChannel：
    //   Flutter → iOS:  invokeMethod('requestPermissionAndRegister') 弹权限 + 调 registerForRemoteNotifications
    //   iOS → Flutter:  invokeMethod('onDeviceToken', args: hexToken)
    let messenger = engineBridge.applicationRegistrar.messenger
    let channel = FlutterMethodChannel(name: AppDelegate.pushChannelName, binaryMessenger: messenger)
    self.pushChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "requestPermissionAndRegister":
        self?.requestPermissionAndRegister(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // ───────────────────────────── 权限 + 注册 ─────────────────────────────

  private func requestPermissionAndRegister(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { granted, error in
      DispatchQueue.main.async {
        if let error = error {
          result(["granted": false, "error": error.localizedDescription])
          return
        }
        if granted {
          UIApplication.shared.registerForRemoteNotifications()
        }
        result(["granted": granted])
      }
    }
  }

  // APNs 注册成功 —— 把 deviceToken 转 hex 发给 Flutter
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    NSLog("[APNs] deviceToken: \(hex)")
    pushChannel?.invokeMethod("onDeviceToken", arguments: hex)
  }

  // APNs 注册失败 —— 通知 Flutter
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[APNs] register failed: \(error)")
    pushChannel?.invokeMethod("onRegisterError", arguments: error.localizedDescription)
  }

  // ────────── 前台 / 后台收到通知（即使没杀进程，UNUserNotificationCenter 也会回调）──────────

  // 前台收到通知时是否仍然弹 banner / 响声
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .badge, .sound, .list])
  }

  // 用户点了通知（不论 app 在哪个状态下点的）—— 把 payload 给 Flutter，让它跳到对应聊天
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    pushChannel?.invokeMethod("onNotificationTap", arguments: userInfo)
    completionHandler()
  }
}
