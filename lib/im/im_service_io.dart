import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import '../i18n/framework_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/auth_service.dart';
import '../config/app_config.dart';
import 'apns_service.dart';
import 'fcm_service.dart';

/// IMService.friendshipStream 推的事件类型
enum FriendshipEventKind {
  applicationAdded,    // 收到一条好友申请
  applicationAccepted, // 我发的申请被对方同意
  applicationRejected, // 我发的申请被拒绝
  added,               // 双向好友建立完成（FriendInfo）
  deleted,             // 好友被删除
  infoChanged,         // 好友资料更新
}

class FriendshipEvent {
  final FriendshipEventKind kind;
  final dynamic payload; // FriendApplicationInfo / FriendInfo / BlacklistInfo

  const FriendshipEvent._(this.kind, this.payload);

  factory FriendshipEvent.applicationAdded(dynamic p) =>
      FriendshipEvent._(FriendshipEventKind.applicationAdded, p);
  factory FriendshipEvent.applicationAccepted(dynamic p) =>
      FriendshipEvent._(FriendshipEventKind.applicationAccepted, p);
  factory FriendshipEvent.applicationRejected(dynamic p) =>
      FriendshipEvent._(FriendshipEventKind.applicationRejected, p);
  factory FriendshipEvent.added(dynamic p) =>
      FriendshipEvent._(FriendshipEventKind.added, p);
  factory FriendshipEvent.deleted(dynamic p) =>
      FriendshipEvent._(FriendshipEventKind.deleted, p);
  factory FriendshipEvent.infoChanged(dynamic p) =>
      FriendshipEvent._(FriendshipEventKind.infoChanged, p);
}

/// OpenIM SDK 封装服务
/// 负责: 初始化 SDK、登录/登出、消息监听、连接状态管理
class IMService {
  static final IMService _instance = IMService._();
  static IMService get instance => _instance;
  IMService._();

  static String get _backendUrl => AppConfig.backendUrl;
  static const String _imTokenKey = 'im_token';
  static const String _imUserIdKey = 'im_user_id';
  static const String _imWsUrlKey = 'im_ws_url';
  static const String _imApiUrlKey = 'im_api_url';

  String? _imToken;
  String? _imUserId;
  String? _wsUrl;
  String? _apiUrl;

  bool _initialized = false;
  bool _loggedIn = false;
  // 复用进行中的 login future，防止 `_AuthGate.build()` 反复触发登录（rebuild 重入）
  Future<bool>? _loginInFlight;

  final ValueNotifier<bool> connectionNotifier = ValueNotifier(false);
  final ValueNotifier<int> unreadCountNotifier = ValueNotifier(0);

  // ── 事件 stream（broadcast；多个页面可同时订阅）──
  // OpenIM SDK 的 setXxxListener 是"单 listener"语义，谁后调谁覆盖。所以所有 listener
  // 集中在 IMService 这里订一次，页面通过下面的 stream 拿事件，避免相互踩。
  final StreamController<Message> _newMessageCtrl = StreamController.broadcast();
  final StreamController<RevokedInfo> _revokedCtrl = StreamController.broadcast();
  final StreamController<List<ReadReceiptInfo>> _c2cReceiptCtrl = StreamController.broadcast();
  final StreamController<List<ConversationInfo>> _conversationsChangedCtrl =
      StreamController.broadcast();
  final StreamController<FriendshipEvent> _friendshipCtrl = StreamController.broadcast();

  Stream<Message> get newMessageStream => _newMessageCtrl.stream;
  Stream<RevokedInfo> get revokedStream => _revokedCtrl.stream;
  Stream<List<ReadReceiptInfo>> get c2cReceiptStream => _c2cReceiptCtrl.stream;
  Stream<List<ConversationInfo>> get conversationsChangedStream =>
      _conversationsChangedCtrl.stream;
  Stream<FriendshipEvent> get friendshipStream => _friendshipCtrl.stream;

  bool get isLoggedIn => _loggedIn;
  String? get currentUserId => _imUserId;

  /// flutter_openim_sdk 仅支持 iOS / Android。
  /// macOS / Web / Windows / Linux 调任何 OpenIM 方法都会抛 MissingPluginException。
  /// 上层用这个 flag 决定要不要展示消息入口 / 直接 short-circuit login。
  static bool get isPlatformSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
  }

  /// 初始化 SDK (App 启动时调用一次)
  ///
  /// 注意：dataDir 必须传可写目录（iOS 沙盒不允许写根目录 / 上）。
  /// 之前传空字符串 → SDK 拼出 `/OpenIM_v3_<userID>.db` → 10006 init database 失败。
  ///
  /// ⚠️ 关键：dataDir 创建逻辑必须放在 `if (_initialized) return` 之前。
  /// 切账号 wipe 会删整个 ${appSupport}/openim/ 目录，但 IMService 单例
  /// 的 _initialized=true 标记不会被重置（它和磁盘状态无关）。下次
  /// _doLogin 调 init() 时如果直接 return，SDK 还是用着原来的 dataDir
  /// 路径，但磁盘上目录已没了 → SDK login 时打开 SQLite "no such file
  /// or directory" → 10006 init database failed。所以哪怕 SDK 已 init，
  /// 也要确保目录还在。
  Future<void> init() async {
    // OpenIM SDK 内部用 dataDir + 文件名拼绝对路径，所以末尾必须带 /
    final dir = await getApplicationSupportDirectory();
    final imDir = Directory('${dir.path}/openim');
    if (!await imDir.exists()) {
      await imDir.create(recursive: true);
      debugPrint('[IM] (re)created dataDir: ${imDir.path}');
    }
    final dataDir = '${imDir.path}/'; // 末尾的 / 不能漏，SDK 直接拼

    if (_initialized) return;

    try {
      // 兜底超时 —— flutter_openim_sdk 在 Android release 下若缺 ACCESS_NETWORK_STATE
      // 权限 / Go runtime 异常 时 initSDK 会永不返回，导致 _loginInFlight 锁死、UI
      // 后续点击全部无反应。这里 15s 超时让上层能感知到失败并重试
      await OpenIM.iMManager.initSDK(
        platformID: _getPlatformID(),
        apiAddr: _apiUrl ?? AppConfig.imApiUrl,
        wsAddr: _wsUrl ?? AppConfig.imWsUrl,
        dataDir: dataDir,
        listener: OnConnectListener(
          onConnectSuccess: () {
            debugPrint('[IM] 连接成功');
            connectionNotifier.value = true;
          },
          onConnecting: () {
            debugPrint('[IM] 连接中...');
          },
          onConnectFailed: (code, error) {
            debugPrint('[IM] 连接失败: $code $error');
            connectionNotifier.value = false;
          },
          onUserTokenExpired: () {
            debugPrint('[IM] Token 过期, 尝试刷新');
            _refreshIMToken();
          },
          onUserTokenInvalid: () {
            debugPrint('[IM] Token 无效');
            connectionNotifier.value = false;
            _loggedIn = false;
          },
          onKickedOffline: () {
            debugPrint('[IM] 被踢下线');
            connectionNotifier.value = false;
            _loggedIn = false;
          },
        ),
      ).timeout(const Duration(seconds: 15));

      _setupListeners();
      _initialized = true;
      debugPrint('[IM] initSDK ok, dataDir=$dataDir');
    } catch (e) {
      // init 失败时**不**置 _initialized=true，让下次 login 能重新 init
      debugPrint('[IM] initSDK 失败: $e');
      rethrow;
    }
  }

  /// 设置全局监听 —— 所有 OpenIM listener 都在这里统一订一次
  /// 页面 / 组件不要自己调 setXxxListener（会被覆盖），改订阅本服务的 stream。
  void _setupListeners() {
    OpenIM.iMManager.messageManager.setAdvancedMsgListener(OnAdvancedMsgListener(
      onRecvNewMessage: (msg) {
        debugPrint('[IM] 新消息: ${msg.senderNickname} -> ${msg.contentType}');
        _newMessageCtrl.add(msg);
        _updateUnreadCount();
      },
      onNewRecvMessageRevoked: (info) {
        debugPrint('[IM] 消息撤回: ${info.clientMsgID}');
        _revokedCtrl.add(info);
      },
      onRecvC2CReadReceipt: (list) {
        debugPrint('[IM] 已读回执: ${list.length} 条');
        _c2cReceiptCtrl.add(list);
      },
    ));

    OpenIM.iMManager.conversationManager.setConversationListener(
      OnConversationListener(
        onConversationChanged: (list) {
          _conversationsChangedCtrl.add(list);
          _updateUnreadCount();
        },
        onNewConversation: (list) {
          _conversationsChangedCtrl.add(list);
          _updateUnreadCount();
        },
        onTotalUnreadMessageCountChanged: (count) {
          unreadCountNotifier.value = count;
        },
      ),
    );

    OpenIM.iMManager.friendshipManager.setFriendshipListener(OnFriendshipListener(
      onFriendApplicationAdded: (a) =>
          _friendshipCtrl.add(FriendshipEvent.applicationAdded(a)),
      onFriendApplicationAccepted: (a) =>
          _friendshipCtrl.add(FriendshipEvent.applicationAccepted(a)),
      onFriendApplicationRejected: (a) =>
          _friendshipCtrl.add(FriendshipEvent.applicationRejected(a)),
      onFriendAdded: (f) => _friendshipCtrl.add(FriendshipEvent.added(f)),
      onFriendDeleted: (f) => _friendshipCtrl.add(FriendshipEvent.deleted(f)),
      onFriendInfoChanged: (f) => _friendshipCtrl.add(FriendshipEvent.infoChanged(f)),
    ));
  }

  /// 登录 OpenIM
  /// 先从后端获取 IM token, 然后调用 SDK login
  ///
  /// 幂等：已登录时直接返回 true；进行中时返回同一个 future，避免 `_AuthGate`
  /// 重 build 时多次发起登录请求。
  Future<bool> login() async {
    if (!isPlatformSupported) {
      // macOS / Web / Windows / Linux —— SDK 不支持，直接 short-circuit
      return false;
    }
    if (!AuthService.isLoggedIn) return false;
    if (_loggedIn) return true;
    if (_loginInFlight != null) return _loginInFlight!;

    final future = _doLogin();
    _loginInFlight = future;
    try {
      return await future;
    } finally {
      _loginInFlight = null;
    }
  }

  /// 实际登录流程。最多重试 3 次（间隔 1s / 2s 退避），兜底以下场景：
  /// - 首次注册的用户 backend 还在 provision OpenIM 账号，第一次 SDK login
  ///   会以 user not exists / 类似错误失败
  /// - SDK 一过性的 init / 网络抖动
  /// - 偶发的 dataDir 状态不一致（init() 已加保护，但留个兜底无伤大雅）
  Future<bool> _doLogin() async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final credentials = await _fetchIMCredentials();
        if (credentials == null) {
          lastError = 'fetch credentials returned null';
        } else {
          _imUserId = credentials['im_user_id'];
          _imToken = credentials['im_token'];
          _wsUrl = credentials['ws_url'];
          _apiUrl = credentials['api_url'];
          await _saveCredentials();

          // init() 内部保证 dataDir 存在（即使 _initialized=true 也会重建目录），
          // 防止 wipe 删目录后 SDK login 打不开 SQLite
          await init();

          await OpenIM.iMManager.login(
            userID: _imUserId!,
            token: _imToken!,
          );

          _loggedIn = true;
          connectionNotifier.value = true;
          await _updateUnreadCount();

          // iOS 真机：启动 APNs（弹权限 → 拿 deviceToken → 上传后端）
          // Android：启动 FCM（同样流程，走 Firebase Messaging）
          // 两个都是 noop-safe on unsupported platforms（kIsWeb / 桌面 / 不匹配的 OS）
          // ignore: unawaited_futures
          ApnsService.instance.start();
          // ignore: unawaited_futures
          FcmService.instance.start();

          debugPrint('[IM] 登录成功: $_imUserId (attempt $attempt/3)');
          return true;
        }
      } catch (e) {
        lastError = e;
      }
      debugPrint('[IM] 登录失败 (attempt $attempt/3): $lastError');
      if (attempt < 3) {
        await Future.delayed(Duration(seconds: attempt));
      }
    }
    return false;
  }

  /// 登出
  Future<void> logout() async {
    try {
      if (_loggedIn) {
        await OpenIM.iMManager.logout();
      }
    } catch (_) {}
    _loggedIn = false;
    connectionNotifier.value = false;
    unreadCountNotifier.value = 0;
    await _clearCredentials();
  }

  /// 从本地恢复 IM 会话 (App 启动时调用)
  ///
  /// 与 [login] 共享 `_loginInFlight`，避免和 `_AuthGate` 触发的 login()
  /// 同时跑出两条登录链路。
  Future<bool> restoreSession() async {
    if (!isPlatformSupported) return false;
    if (_loggedIn) return true;
    if (_loginInFlight != null) return _loginInFlight!;

    final future = _doRestoreSession();
    _loginInFlight = future;
    try {
      return await future;
    } finally {
      _loginInFlight = null;
    }
  }

  Future<bool> _doRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _imToken = prefs.getString(_imTokenKey);
    _imUserId = prefs.getString(_imUserIdKey);
    _wsUrl = prefs.getString(_imWsUrlKey);
    _apiUrl = prefs.getString(_imApiUrlKey);

    if (_imToken != null && _imUserId != null) {
      try {
        await init();
        await OpenIM.iMManager.login(
          userID: _imUserId!,
          token: _imToken!,
        );
        _loggedIn = true;
        connectionNotifier.value = true;
        await _updateUnreadCount();
        // ignore: unawaited_futures
        ApnsService.instance.start();
        // ignore: unawaited_futures
        FcmService.instance.start();
        return true;
      } catch (e) {
        debugPrint('[IM] 恢复会话失败, 尝试重新获取 token: $e');
        return await _doLogin();
      }
    }
    return false;
  }

  // ---------- 消息操作 ----------

  /// 创建一条本地文本消息（不发送，只是 SDK 帮你拼好 Message 结构 + 分配 clientMsgID）
  /// 给乐观 UI 用：先 create 拿到 Message → 立刻插入 list 显示 → 后台再 send
  Future<Message> createTextMessage(String text) {
    return OpenIM.iMManager.messageManager.createTextMessage(text: text);
  }

  /// 发送一条已经 create 好的消息（不再走 createXxxMessage 那一步）
  /// 调用方拿到的 Message status 一开始是 sending，发送成功后 SDK 会把
  /// 同一个 clientMsgID 的 Message 改成 sendSuccess（或 sendFailed）
  /// 返回的 Message 就是更新后的版本（如果失败返回 null）
  Future<Message?> sendPreparedMessage({
    required Message message,
    required String previewText,
    String? userID,
    String? groupID,
  }) async {
    if ((userID == null || userID.isEmpty) &&
        (groupID == null || groupID.isEmpty)) {
      debugPrint('[IM] sendPreparedMessage: 必须提供 userID 或 groupID');
      return null;
    }
    try {
      return await OpenIM.iMManager.messageManager.sendMessage(
        message: message,
        offlinePushInfo: OfflinePushInfo(
          title: T.current.imPushNewMessage,
          desc: previewText.length > 50 ? '${previewText.substring(0, 50)}...' : previewText,
        ),
        userID: userID,
        groupID: groupID,
      );
    } catch (e) {
      debugPrint('[IM] 发送失败: $e');
      return null;
    }
  }

  /// （旧路径，保留兼容）一次性发文本：create + send 都阻塞 await
  /// 推荐用 createTextMessage + sendPreparedMessage 实现乐观 UI
  Future<Message?> sendTextMessage({
    required String conversationID,
    required String text,
    String? userID,
    String? groupID,
  }) async {
    final msg = await createTextMessage(text);
    return sendPreparedMessage(
      message: msg,
      previewText: text,
      userID: userID,
      groupID: groupID,
    );
  }

  /// 发送图片消息（旧路径，让 SDK 自己上传到 OpenIM 自带 MinIO）
  /// 已不推荐 —— 走 [sendImageByUrl] 用我们自己的 MinIO 桶 (im-media)
  /// 让存储后端可控、统一 lifecycle。
  /// [userID] / [groupID] 二选一，参见 [sendTextMessage]
  Future<Message?> sendImageMessage({
    required String conversationID,
    required String imagePath,
    String? userID,
    String? groupID,
  }) async {
    if ((userID == null || userID.isEmpty) &&
        (groupID == null || groupID.isEmpty)) {
      debugPrint('[IM] sendImageMessage: 必须提供 userID 或 groupID');
      return null;
    }
    try {
      final msg = await OpenIM.iMManager.messageManager.createImageMessageFromFullPath(
        imagePath: imagePath,
      );
      return await OpenIM.iMManager.messageManager.sendMessage(
        message: msg,
        offlinePushInfo: OfflinePushInfo(title: T.current.imPushNewMessage, desc: T.current.imPushImagePreview),
        userID: userID,
        groupID: groupID,
      );
    } catch (e) {
      debugPrint('[IM] 发送图片失败: $e');
      return null;
    }
  }

  /// 发送图片消息（推荐路径）：图片已经通过 ImMediaUploader 上传到我们自己的
  /// MinIO，[url] 是公网可读 URL。这里只调用 SDK 的 createImageMessageByURL
  /// 把 URL 包成系统 picture 消息，对端走原生 picture 渲染管线。
  ///
  /// [width] / [height] / [size] 是图片元数据，对端列表里展示缩略图时不需要
  /// 现下载就能算出 aspect ratio，体验更好。size 是字节数。
  /// [thumbUrl] 可选缩略图 URL；不传时用 [url] 顶替（OpenIM 列表会重复请求
  /// 大图当 thumbnail，移动端流量略多但功能正确）。
  ///
  /// **重要**：[sourcePath] 必传 —— SDK 会在 native 端用这个本地文件计算 MD5
  /// 当 message UUID，不传或文件不存在会报 PlatformException 10005。
  /// [uuid] 是 PictureInfo.uuid 字段，全局唯一即可；推荐用 MinIO 的 object key。
  Future<Message?> sendImageByUrl({
    required String url,
    required String sourcePath,
    required String uuid,
    required int width,
    required int height,
    required int size,
    String? thumbUrl,
    String? userID,
    String? groupID,
  }) async {
    final pic = PictureInfo()
      ..uuid = uuid
      ..url = url
      ..width = width
      ..height = height
      ..size = size
      ..type = 'image/jpeg';
    final thumbPic = (thumbUrl == null || thumbUrl.isEmpty)
        ? pic
        : (PictureInfo()
          ..uuid = '${uuid}_thumb'
          ..url = thumbUrl
          ..width = width
          ..height = height
          ..type = 'image/jpeg');
    try {
      final msg = await OpenIM.iMManager.messageManager.createImageMessageByURL(
        sourcePath: sourcePath,
        sourcePicture: pic,
        bigPicture: pic,
        snapshotPicture: thumbPic,
      );
      return sendPreparedMessage(
        message: msg,
        previewText: '[图片]',
        userID: userID,
        groupID: groupID,
      );
    } catch (e) {
      debugPrint('[IM] sendImageByUrl 失败: $e');
      return null;
    }
  }

  /// 发送视频消息（推荐路径）：视频本体和首帧缩略图都已上传到我们 MinIO。
  /// SDK 把 URL 包成系统 video 消息，对端 picture/video bubble 渲染管线会
  /// 自动处理缩略图 + 全屏播放。
  ///
  /// [videoSourcePath] / [snapshotSourcePath] 必传 —— SDK 在 native 端用
  /// 它们计算 MD5（同 sendImageByUrl 的踩坑）。
  Future<Message?> sendVideoByUrl({
    required String videoUrl,
    required String videoSourcePath,
    required String videoUuid,
    required String videoType, // 'video/mp4' / 'video/quicktime' 等
    required int videoSize,
    required int duration,
    required String snapshotUrl,
    required String snapshotSourcePath,
    required String snapshotUuid,
    required int snapshotSize,
    required int snapshotWidth,
    required int snapshotHeight,
    String? userID,
    String? groupID,
  }) async {
    final elem = VideoElem(
      videoPath: videoSourcePath,
      videoUUID: videoUuid,
      videoUrl: videoUrl,
      videoType: videoType,
      videoSize: videoSize,
      duration: duration,
      snapshotPath: snapshotSourcePath,
      snapshotUUID: snapshotUuid,
      snapshotSize: snapshotSize,
      snapshotUrl: snapshotUrl,
      snapshotWidth: snapshotWidth,
      snapshotHeight: snapshotHeight,
    );
    try {
      final msg = await OpenIM.iMManager.messageManager.createVideoMessageByURL(
        videoElem: elem,
      );
      return sendPreparedMessage(
        message: msg,
        previewText: '[视频]',
        userID: userID,
        groupID: groupID,
      );
    } catch (e) {
      debugPrint('[IM] sendVideoByUrl 失败: $e');
      return null;
    }
  }

  /// 发送文件消息（推荐路径）：文件已上传到我们 MinIO，[url] 公网可读。
  /// SDK 把 URL 包成系统 file 消息，对端 file bubble 渲染管线会处理点击下载。
  ///
  /// [sourcePath] 必传 —— SDK 在 native 端用它算 MD5 当 message UUID。
  Future<Message?> sendFileByUrl({
    required String url,
    required String sourcePath,
    required String uuid,
    required String fileName,
    required int fileSize,
    String? userID,
    String? groupID,
  }) async {
    final elem = FileElem(
      filePath: sourcePath,
      uuid: uuid,
      sourceUrl: url,
      fileName: fileName,
      fileSize: fileSize,
    );
    try {
      final msg = await OpenIM.iMManager.messageManager.createFileMessageByURL(
        fileElem: elem,
      );
      return sendPreparedMessage(
        message: msg,
        previewText: '[文件] $fileName',
        userID: userID,
        groupID: groupID,
      );
    } catch (e) {
      debugPrint('[IM] sendFileByUrl 失败: $e');
      return null;
    }
  }

  /// 撤回消息
  Future<bool> revokeMessage({
    required String conversationID,
    required Message message,
  }) async {
    try {
      await OpenIM.iMManager.messageManager.revokeMessage(
        conversationID: conversationID,
        clientMsgID: message.clientMsgID!,
      );
      return true;
    } catch (e) {
      debugPrint('[IM] 撤回失败: $e');
      return false;
    }
  }

  /// 标记消息已读
  ///
  /// SDK 内部会触发 onTotalUnreadMessageCountChanged，但有时（特别是没新消息进来
  /// 只是清旧未读时）回调延迟或不触发，所以这里手动 _updateUnreadCount() 兜底。
  Future<void> markConversationRead({required String conversationID}) async {
    try {
      await OpenIM.iMManager.conversationManager.markConversationMessageAsRead(
        conversationID: conversationID,
      );
      // 立刻刷一次总未读数，不依赖回调时机
      await _updateUnreadCount();
    } catch (e) {
      debugPrint('[IM] 标记已读失败: $e');
    }
  }

  // ---------- 会话操作 ----------

  /// 获取会话列表
  Future<List<ConversationInfo>> getConversationList() async {
    try {
      final list = await OpenIM.iMManager.conversationManager
          .getConversationListSplit(offset: 0, count: 100);
      return list;
    } catch (e) {
      debugPrint('[IM] 获取会话列表失败: $e');
      return [];
    }
  }

  /// 获取历史消息
  Future<List<Message>> getHistoryMessages({
    required String conversationID,
    Message? startMsg,
    int count = 20,
  }) async {
    try {
      final result = await OpenIM.iMManager.messageManager
          .getAdvancedHistoryMessageList(
        conversationID: conversationID,
        startMsg: startMsg,
        count: count,
      );
      return result.messageList ?? [];
    } catch (e) {
      debugPrint('[IM] 获取历史消息失败: $e');
      return [];
    }
  }

  /// 按 userID 列表批量取 OpenIM 端的公开用户信息（昵称、头像、ex 等）
  /// 注意：OpenIM 这边的 faceURL 只在用户首次注册时写一次，Supabase 头像之后改了
  /// 不会同步过去——所以拿到的头像往往是空。要拿真实头像用 lookupUsersFromSupabase。
  Future<List<PublicUserInfo>> getUsersInfo(List<String> userIDList) async {
    if (userIDList.isEmpty) return [];
    try {
      return await OpenIM.iMManager.userManager
          .getUsersInfo(userIDList: userIDList);
    } catch (e) {
      debugPrint('[IM] 获取用户信息失败: $e');
      return [];
    }
  }

  /// 按 userID 列表去后端 /api/im/users/search 查 Supabase 的头像/昵称。
  /// Supabase 是 avatar 真实源（OpenIM 的 faceURL 不会跟着 Supabase 更新）。
  /// 用 search 是因为 lookup 接口走的是 OpenIM（也拿不到新数据），search 走 Supabase。
  /// 返回 map: userID → {im_user_id, nickname, email, face_url}。
  /// 找不到的 userID 不会出现在返回 map 里。
  Future<Map<String, Map<String, dynamic>>> lookupUsersFromSupabase(
      List<String> userIDList) async {
    if (userIDList.isEmpty) return const {};
    // 去重 + 过滤空 ID
    final uniqIds = userIDList.where((s) => s.isNotEmpty).toSet().toList();
    if (uniqIds.isEmpty) return const {};

    final entries = await Future.wait(uniqIds.map((id) async {
      try {
        final hits = await searchUsers(id);
        for (final u in hits) {
          if ((u['im_user_id']?.toString() ?? '') == id) {
            return MapEntry(id, u);
          }
        }
      } catch (e) {
        debugPrint('[IM] supabase lookup 失败 user=$id: $e');
      }
      return null;
    }));
    return Map.fromEntries(
        entries.whereType<MapEntry<String, Map<String, dynamic>>>());
  }

  // ---------- 群聊操作 ----------

  /// 创建群聊
  Future<GroupInfo?> createGroup({
    required String groupName,
    required List<String> memberUserIDs,
    String? faceURL,
  }) async {
    try {
      final info = GroupInfo(groupID: '', groupName: groupName, faceURL: faceURL ?? '');
      final group = await OpenIM.iMManager.groupManager.createGroup(
        groupInfo: info,
        memberUserIDs: memberUserIDs,
      );
      return group;
    } catch (e) {
      debugPrint('[IM] 创建群聊失败: $e');
      return null;
    }
  }

  /// 获取已加入的群列表
  Future<List<GroupInfo>> getJoinedGroups() async {
    try {
      return await OpenIM.iMManager.groupManager.getJoinedGroupList();
    } catch (e) {
      debugPrint('[IM] 获取群列表失败: $e');
      return [];
    }
  }

  // ---------- 好友 / 联系人 ----------

  /// 拉好友列表
  Future<List<FriendInfo>> getFriendList() async {
    try {
      return await OpenIM.iMManager.friendshipManager.getFriendList();
    } catch (e) {
      debugPrint('[IM] 获取好友列表失败: $e');
      return [];
    }
  }

  /// 给指定 userID 发好友申请。OpenIM 默认走"申请-同意"流，对方在
  /// `getFriendApplicationListAsRecipient` 里能看到。
  /// [reqMsg] 申请附言（"我是 xxx"）。
  Future<bool> sendFriendApplication({
    required String userID,
    String reqMsg = '',
  }) async {
    try {
      await OpenIM.iMManager.friendshipManager.addFriend(
        userID: userID,
        reason: reqMsg,
      );
      return true;
    } catch (e) {
      debugPrint('[IM] 发送好友申请失败: $e');
      return false;
    }
  }

  /// 我收到的好友申请列表（待处理 / 历史）
  Future<List<FriendApplicationInfo>> getIncomingFriendApplications() async {
    try {
      return await OpenIM.iMManager.friendshipManager
          .getFriendApplicationListAsRecipient();
    } catch (e) {
      debugPrint('[IM] 获取收到的好友申请失败: $e');
      return [];
    }
  }

  /// 我发出的好友申请列表（待对方处理）
  Future<List<FriendApplicationInfo>> getOutgoingFriendApplications() async {
    try {
      return await OpenIM.iMManager.friendshipManager
          .getFriendApplicationListAsApplicant();
    } catch (e) {
      debugPrint('[IM] 获取发出的好友申请失败: $e');
      return [];
    }
  }

  /// 同意好友申请
  Future<bool> acceptFriendApplication({
    required String fromUserID,
    String handleMsg = '',
  }) async {
    try {
      await OpenIM.iMManager.friendshipManager.acceptFriendApplication(
        userID: fromUserID,
        handleMsg: handleMsg,
      );
      return true;
    } catch (e) {
      debugPrint('[IM] 同意好友申请失败: $e');
      return false;
    }
  }

  /// 拒绝好友申请
  Future<bool> rejectFriendApplication({
    required String fromUserID,
    String handleMsg = '',
  }) async {
    try {
      await OpenIM.iMManager.friendshipManager.refuseFriendApplication(
        userID: fromUserID,
        handleMsg: handleMsg,
      );
      return true;
    } catch (e) {
      debugPrint('[IM] 拒绝好友申请失败: $e');
      return false;
    }
  }

  /// 删除好友
  Future<bool> deleteFriend(String userID) async {
    try {
      await OpenIM.iMManager.friendshipManager.deleteFriend(userID: userID);
      return true;
    } catch (e) {
      debugPrint('[IM] 删除好友失败: $e');
      return false;
    }
  }

  /// 查 OpenIM 用户基础信息（用于"加好友"前先校验对方 user_id 真实存在）
  /// 走后端 /api/im/users/lookup（后端有 admin token 才查得到陌生用户）
  Future<Map<String, dynamic>?> lookupUser(String userID) async {
    try {
      final resp = await http.get(
        Uri.parse('$_backendUrl/api/im/users/lookup?user_id=${Uri.encodeQueryComponent(userID)}'),
        headers: {'Authorization': 'Bearer ${AuthService.token}'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint('[IM] lookupUser 失败 ${resp.statusCode}: ${resp.body}');
        return null;
      }
      return json.decode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[IM] lookupUser 异常: $e');
      return null;
    }
  }

  /// 搜索用户。q 可以是 email / username / uuid（带或不带 hyphen）模糊匹配。
  /// 至少 2 个字符才发请求；返回每条 {im_user_id, nickname, email, face_url}
  Future<List<Map<String, dynamic>>> searchUsers(String q) async {
    if (q.trim().length < 2) return const [];
    try {
      final resp = await http.get(
        Uri.parse('$_backendUrl/api/im/users/search?q=${Uri.encodeQueryComponent(q.trim())}'),
        headers: {'Authorization': 'Bearer ${AuthService.token}'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint('[IM] searchUsers 失败 ${resp.statusCode}: ${resp.body}');
        return const [];
      }
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return List<Map<String, dynamic>>.from(data['users'] ?? const []);
    } catch (e) {
      debugPrint('[IM] searchUsers 异常: $e');
      return const [];
    }
  }

  // ※ 旧的 setFriendshipListener 已移除：OpenIM SDK 单 listener 语义会让页面之间互相覆盖。
  //   订阅 friendshipStream 替代。

  // ---------- FCM 推送 ----------

  /// 注册 FCM token
  Future<void> registerFCMToken(String fcmToken) async {
    try {
      final resp = await http.post(
        Uri.parse('$_backendUrl/api/im/push_token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AuthService.token}',
        },
        body: json.encode({
          'fcm_token': fcmToken,
          'platform': _getPlatformID(),
        }),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        debugPrint('[IM] FCM token 注册失败: ${resp.body}');
      }
    } catch (e) {
      debugPrint('[IM] FCM token 注册异常: $e');
    }
  }

  // ---------- 内部方法 ----------

  Future<Map<String, dynamic>?> _fetchIMCredentials() async {
    try {
      final resp = await http.post(
        Uri.parse('$_backendUrl/api/im/token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AuthService.token}',
        },
        body: json.encode({'platform': _getPlatformID()}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        debugPrint('[IM] 获取凭证失败: ${resp.body}');
        return null;
      }
      return json.decode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[IM] 获取凭证异常: $e');
      return null;
    }
  }

  Future<void> _refreshIMToken() async {
    final credentials = await _fetchIMCredentials();
    if (credentials != null) {
      _imToken = credentials['im_token'];
      await _saveCredentials();
      try {
        await OpenIM.iMManager.login(
          userID: _imUserId!,
          token: _imToken!,
        );
        _loggedIn = true;
        connectionNotifier.value = true;
      } catch (e) {
        debugPrint('[IM] Token 刷新后重连失败: $e');
      }
    }
  }

  Future<void> _updateUnreadCount() async {
    try {
      final result = await OpenIM.iMManager.conversationManager
          .getTotalUnreadMsgCount();
      // SDK 文档说明 getTotalUnreadMsgCount 返回字符串形式的数字（int.tryParse）
      // 老代码 `result is int` 永远返回 false，未读数永远为 0。
      int count;
      if (result is int) {
        count = result;
      } else if (result is String) {
        count = int.tryParse(result) ?? 0;
      } else {
        count = int.tryParse('$result') ?? 0;
      }
      unreadCountNotifier.value = count;
    } catch (_) {}
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_imToken != null) await prefs.setString(_imTokenKey, _imToken!);
    if (_imUserId != null) await prefs.setString(_imUserIdKey, _imUserId!);
    if (_wsUrl != null) await prefs.setString(_imWsUrlKey, _wsUrl!);
    if (_apiUrl != null) await prefs.setString(_imApiUrlKey, _apiUrl!);
  }

  Future<void> _clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_imTokenKey);
    await prefs.remove(_imUserIdKey);
    await prefs.remove(_imWsUrlKey);
    await prefs.remove(_imApiUrlKey);
  }

  // OpenIM 平台 ID：1=iOS 2=Android 3=Windows 4=macOS 5=Web 7=Linux 8=Android Pad 9=iPad
  int _getPlatformID() {
    if (kIsWeb) return 5;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 1;
      case TargetPlatform.android:
        return 2;
      case TargetPlatform.windows:
        return 3;
      case TargetPlatform.macOS:
        return 4;
      case TargetPlatform.linux:
        return 7;
      default:
        return 5; // 兜底用 Web，后端不在意精确值，只要不撞群聊一致性就行
    }
  }

  // ========== JSON-DSL 桥接 ==========
  // 这一组方法返回纯 Map / 基本类型，**不把 OpenIM 的 FriendInfo/Message/
  // ConversationInfo 等类型泄漏给 interpreter**。interpreter 因此不必 import
  // flutter_openim_sdk，web 端 im_service_web.dart 的 stub 也只需实现这些方法。

  /// 好友 userID 集合（@im_search_users 标记 is_friend 用）。
  Future<Set<String>> getFriendIds() async {
    final friends = await getFriendList();
    return friends.map((f) => f.userID).whereType<String>().toSet();
  }

  Future<List<Map<String, dynamic>>> getFriendListAsMaps() async {
    final friends = await getFriendList();
    return friends.map(_friendInfoToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getIncomingFriendApplicationsAsMaps() async {
    final apps = await getIncomingFriendApplications();
    return apps.map(_friendApplicationToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getConversationListAsMaps() async {
    final convos = await getConversationList();
    return convos.map(_conversationToMap).toList();
  }

  /// 跨所有会话的未读总数（tab badge / 角标）。
  Future<int> getTotalUnread() async {
    final convos = await getConversationList();
    int total = 0;
    for (final c in convos) {
      total += c.unreadCount;
    }
    return total;
  }

  Future<List<Map<String, dynamic>>> getHistoryMessagesAsMaps({
    required String conversationID,
    int count = 30,
  }) async {
    final messages =
        await getHistoryMessages(conversationID: conversationID, count: count);
    return messages.map(_messageToMap).toList();
  }

  Future<Map<String, dynamic>?> sendTextMessageAsMap({
    required String conversationID,
    required String text,
    required String userID,
  }) async {
    final msg = await sendTextMessage(
        conversationID: conversationID, text: text, userID: userID);
    return msg != null ? _messageToMap(msg) : null;
  }

  /// 新消息流（已转成 Map，interpreter 直接订阅，不依赖 OpenIM Message 类型）。
  Stream<Map<String, dynamic>> get newMessageMapStream =>
      newMessageStream.map(_messageToMap);

  // ── 转换器（原在 interpreter，下沉到这里以隔离 OpenIM 类型）──

  Map<String, dynamic> _friendInfoToMap(FriendInfo f) {
    return {
      'user_id': f.userID ?? '',
      'nickname': f.nickname ?? '',
      'face_url': f.faceURL ?? '',
      'remark': f.remark ?? '',
    };
  }

  Map<String, dynamic> _friendApplicationToMap(FriendApplicationInfo a) {
    return {
      'from_user_id': a.fromUserID ?? '',
      'from_nickname': a.fromNickname ?? '',
      'from_face_url': a.fromFaceURL ?? '',
      'req_msg': a.reqMsg ?? '',
      'handle_result': a.handleResult ?? 0, // 0=待处理 1=已同意 -1=已拒绝
      'create_time': a.createTime ?? 0,
    };
  }

  Map<String, dynamic> _messageToMap(Message m) {
    String text;
    switch (m.contentType) {
      case MessageType.text:
        text = m.textElem?.content ?? '';
        break;
      case MessageType.picture:
        text = '[图片]';
        break;
      case MessageType.video:
        text = '[视频]';
        break;
      case MessageType.voice:
        text = '[语音]';
        break;
      case MessageType.file:
        text = '[文件]';
        break;
      default:
        text = '[消息]';
    }
    final myId = currentUserId ?? '';
    final sendId = m.sendID ?? '';
    final isMe = sendId == myId && sendId.isNotEmpty;
    final sendTime = m.sendTime ?? 0;
    final senderNick = m.senderNickname ?? '';
    // 他人显示名兜底：nick 为空时回退到 sendId（不要让 UI 出现空白发送者）
    final otherDisplay = senderNick.isNotEmpty ? senderNick : sendId;
    return {
      'client_msg_id': m.clientMsgID ?? '',
      'send_id': sendId,
      'recv_id': m.recvID ?? '',
      'send_time': sendTime,
      'content_type': m.contentType ?? 101,
      'text': text,
      'sender_nickname': senderNick,
      'sender_face_url': m.senderFaceUrl ?? '',
      'is_me': isMe,
      // 给 JSON-APP 用的"另一面"flag：is_me 取反，配合 widget visible 字段做
      // 自他分支渲染时不用写 jsonlogic `{"!": [...]}`
      'is_other': !isMe,
      // 预格式化字段：JSON-DSL 不支持条件 / 时间格式表达式，所以在这里算好
      'display_time': _formatChatTime(sendTime),
      'display_sender': isMe ? T.current.imSenderMe : otherDisplay,
      // 微信风格气泡配色：自己绿色（#95EC69），他人白色
      'bubble_color': isMe ? '#95EC69' : '#FFFFFF',
      'bubble_text_color': '#000000',
    };
  }

  Map<String, dynamic> _conversationToMap(ConversationInfo c) {
    String latest;
    final lm = c.latestMsg;
    if (lm == null) {
      latest = '';
    } else {
      latest = _messageToMap(lm)['text'] as String? ?? '';
    }
    final unread = c.unreadCount;
    final latestTime = c.latestMsgSendTime ?? 0;
    return {
      'conversation_id': c.conversationID,
      'user_id': c.userID ?? '',
      'show_name': c.showName ?? '',
      'face_url': c.faceURL ?? '',
      'latest_text': latest,
      'latest_time': latestTime,
      'unread_count': unread,
      // 预格式化：unread 为 0 时空字符串（绑 text.value 直接隐藏徽标视觉）
      'display_unread': unread > 0 ? unread.toString() : '',
      'display_time': _formatChatTime(latestTime),
    };
  }

  /// 把 epoch 毫秒时间戳格式化为 IM 列表常见的"今天 HH:mm / 昨天 / MM-dd"。
  /// 0 / 负数 → 空串（用于"暂无消息"等场景）。
  String _formatChatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dtDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(dtDay).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    // 时钟漂移 / 服务器时间快于本地时（diff < 0）也按"今天 HH:mm"渲染，
    // 避免出现 "−1 天前" 之类怪字符串。
    if (diff <= 0) return '${two(dt.hour)}:${two(dt.minute)}';
    if (diff == 1) return T.current.relativeDateYesterday;
    if (diff < 7) return '$diff天前';
    return '${two(dt.month)}-${two(dt.day)}';
  }
}
