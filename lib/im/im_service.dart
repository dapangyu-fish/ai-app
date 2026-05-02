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
        apiAddr: _apiUrl ?? 'http://127.0.0.1:10002',
        wsAddr: _wsUrl ?? 'ws://127.0.0.1:10001',
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

  /// 设置全局消息监听
  void _setupListeners() {
    OpenIM.iMManager.messageManager.setAdvancedMsgListener(OnAdvancedMsgListener(
      onRecvNewMessage: (msg) {
        debugPrint('[IM] 新消息: ${msg.senderNickname} -> ${msg.contentType}');
        _updateUnreadCount();
      },
      onNewRecvMessageRevoked: (info) {
        debugPrint('[IM] 消息撤回: ${info.clientMsgID}');
      },
      onRecvC2CReadReceipt: (list) {
        debugPrint('[IM] 已读回执: ${list.length} 条');
      },
    ));

    OpenIM.iMManager.conversationManager.setConversationListener(
      OnConversationListener(
        onConversationChanged: (list) {
          _updateUnreadCount();
        },
        onNewConversation: (list) {
          _updateUnreadCount();
        },
        onTotalUnreadMessageCountChanged: (count) {
          unreadCountNotifier.value = count;
        },
      ),
    );
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
        return true;
      } catch (e) {
        debugPrint('[IM] 恢复会话失败, 尝试重新获取 token: $e');
        return await _doLogin();
      }
    }
    return false;
  }

  // ---------- 消息操作 ----------

  /// 发送文本消息
  /// [userID] 1:1 单聊收件人；与 [groupID] 二选一
  /// [groupID] 群聊群 ID；与 [userID] 二选一
  Future<Message?> sendTextMessage({
    required String conversationID,
    required String text,
    String? userID,
    String? groupID,
  }) async {
    if ((userID == null || userID.isEmpty) &&
        (groupID == null || groupID.isEmpty)) {
      debugPrint('[IM] sendTextMessage: 必须提供 userID 或 groupID');
      return null;
    }
    try {
      final msg = await OpenIM.iMManager.messageManager.createTextMessage(
        text: text,
      );
      final result = await OpenIM.iMManager.messageManager.sendMessage(
        message: msg,
        offlinePushInfo: OfflinePushInfo(
          title: '新消息',
          desc: text.length > 50 ? '${text.substring(0, 50)}...' : text,
        ),
        userID: userID,
        groupID: groupID,
      );
      return result;
    } catch (e) {
      debugPrint('[IM] 发送文本失败: $e');
      return null;
    }
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
  Future<void> markConversationRead({required String conversationID}) async {
    try {
      await OpenIM.iMManager.conversationManager.markConversationMessageAsRead(
        conversationID: conversationID,
      );
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

  /// 监听好友申请到达（其它页面订阅这个 listener 实时刷新红点）
  void setFriendshipListener(OnFriendshipListener listener) {
    OpenIM.iMManager.friendshipManager.setFriendshipListener(listener);
  }

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
