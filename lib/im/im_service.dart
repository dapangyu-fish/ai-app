import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/auth_service.dart';
import '../config/app_config.dart';
import 'apns_service.dart';

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
  Future<void> init() async {
    if (_initialized) return;

    // OpenIM SDK 内部用 dataDir + 文件名拼绝对路径，所以末尾必须带 /
    final dir = await getApplicationSupportDirectory();
    final imDir = Directory('${dir.path}/openim');
    if (!await imDir.exists()) {
      await imDir.create(recursive: true);
    }
    final dataDir = '${imDir.path}/'; // 末尾的 / 不能漏，SDK 直接拼

    try {
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
      );

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

  Future<bool> _doLogin() async {
    try {
      final credentials = await _fetchIMCredentials();
      if (credentials == null) return false;

      _imUserId = credentials['im_user_id'];
      _imToken = credentials['im_token'];
      _wsUrl = credentials['ws_url'];
      _apiUrl = credentials['api_url'];

      await _saveCredentials();

      if (!_initialized) {
        await init();
      }

      await OpenIM.iMManager.login(
        userID: _imUserId!,
        token: _imToken!,
      );

      _loggedIn = true;
      connectionNotifier.value = true;
      await _updateUnreadCount();

      // iOS 真机：启动 APNs（弹权限 → 拿 deviceToken → 上传后端）
      // 模拟器调用不会崩，但拿不到真 token；非 iOS 直接 short-circuit
      // ignore: unawaited_futures
      ApnsService.instance.start();

      debugPrint('[IM] 登录成功: $_imUserId');
      return true;
    } catch (e) {
      debugPrint('[IM] 登录失败: $e');
      return false;
    }
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
          title: '新消息',
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

  /// 发送图片消息
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
        offlinePushInfo: OfflinePushInfo(title: '新消息', desc: '[图片]'),
        userID: userID,
        groupID: groupID,
      );
    } catch (e) {
      debugPrint('[IM] 发送图片失败: $e');
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
}
