import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  // 给 Flutter 端发推送 token 用的 channel
  private static let pushChannelName = "dapangyu.fish.myapp/push"
  // 必须强引用：weak 会导致 didInitializeImplicitFlutterEngine 返回后 channel 被释放，
  // 之后 APNs 回调里 invokeMethod 走不通
  private var pushChannel: FlutterMethodChannel?

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
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: AppDelegate.pushChannelName, binaryMessenger: messenger)
    self.pushChannel = channel
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
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
          print("[APNs-iOS] calling registerForRemoteNotifications")
          UIApplication.shared.registerForRemoteNotifications()
        }
        result(["granted": granted])
      }
    }
  }

  // APNs 注册成功 —— 把 deviceToken + 真实 aps-environment 发给 Flutter
  // 为什么要带 env：dev 包的 token 是 sandbox APNs 发的，TF/AppStore 包是 production APNs 发的，
  //   后端必须按这个 env 选 host (api.sandbox.push.apple.com vs api.push.apple.com)，
  //   否则跨环境推会被 Apple 拒回 BadDeviceToken。kReleaseMode/#if DEBUG 都不可靠
  //   （TF 也是 release mode，但 APNs 是 production），所以从 entitlement 读真值
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    let env = AppDelegate.detectApsEnvironment()
    print("[APNs-iOS] deviceToken=\(hex) env=\(env)")
    pushChannel?.invokeMethod("onDeviceToken", arguments: ["token": hex, "env": env])
  }

  // 从 embedded.mobileprovision 读 Entitlements.aps-environment
  // - dev / ad-hoc / enterprise 签名 → 文件存在，env = "development" 或 "production"
  // - AppStore 上架后 Apple 重签可能去掉这文件 → 找不到时按 "production" 兜底（合理：上架包不可能是 sandbox）
  // 模拟器走不到本回调（不会发 APNs token），所以不用考虑
  private static func detectApsEnvironment() -> String {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url) else {
      return "production"
    }
    // mobileprovision 是 CMS-signed PKCS#7 容器，里面 plist 以 ASCII 文本嵌入
    guard let raw = String(data: data, encoding: .ascii),
          let s = raw.range(of: "<plist"),
          let e = raw.range(of: "</plist>", range: s.upperBound..<raw.endIndex),
          let plistData = String(raw[s.lowerBound..<e.upperBound]).data(using: .utf8),
          let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
          let dict = obj as? [String: Any],
          let entitlements = dict["Entitlements"] as? [String: Any],
          let aps = entitlements["aps-environment"] as? String else {
      return "production"
    }
    return aps == "development" ? "development" : "production"
  }

  // APNs 注册失败 —— 通知 Flutter
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("[APNs-iOS] register failed: \(error)")
    pushChannel?.invokeMethod("onRegisterError", arguments: error.localizedDescription)
  }

  // ────────── 前台 / 后台收到通知（即使没杀进程，UNUserNotificationCenter 也会回调）──────────

  // 前台收到通知时是否仍然弹 banner / 响声
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .badge, .sound, .list])
    } else {
      completionHandler([.alert, .badge, .sound])
    }
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
