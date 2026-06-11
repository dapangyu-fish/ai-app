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

  // 先从 Info.plist 读构建期写入的 APNs 环境，读不到再 fallback 到 embedded.mobileprovision。
  // - Debug/Profile 明确写 development；Release 明确写 production。
  // - dev / ad-hoc / enterprise / AppStore 真机：mobileprovision 文件在时按里头的 aps-environment 兜底。
  // - 模拟器：iOS 16+ 模拟器能拿真 APNs token 走 sandbox，但 bundle 里没 mobileprovision —
  //          所以单独短路返 development，不能让兜底落到 production（曾踩此坑：sim 注册成
  //          production 后 Apple 必返 BadDeviceToken，token 还会被自愈逻辑删掉）
  private static func detectApsEnvironment() -> String {
    #if targetEnvironment(simulator)
    return "development"
    #else
    if let env = Bundle.main.object(forInfoDictionaryKey: "MyAppAPNSEnvironment") as? String,
       env == "development" || env == "production" {
      return env
    }
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
    #endif
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
