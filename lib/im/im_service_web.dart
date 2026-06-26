import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../i18n/framework_strings.dart';
import '../platform/openim_web_bridge.dart';

/// OpenIM Web 实现。
///
/// Flutter Web 不能使用 flutter_openim_sdk 的原生插件实现；这里通过
/// `web/openim_bridge.js` 调用 @openim/wasm-client-sdk。
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
  Future<bool>? _loginInFlight;

  final OpenIMWebBridge _bridge = OpenIMWebBridge.instance;

  final ValueNotifier<bool> connectionNotifier = ValueNotifier(false);
  final ValueNotifier<int> unreadCountNotifier = ValueNotifier(0);

  final StreamController<Map<String, dynamic>> _newMessageCtrl =
      StreamController.broadcast();
  final StreamController<void> _conversationChangedCtrl =
      StreamController.broadcast();
  final StreamController<void> _friendshipCtrl = StreamController.broadcast();

  Stream<Map<String, dynamic>> get newMessageMapStream =>
      _newMessageCtrl.stream;
  Stream<void> get conversationsChangedStream =>
      _conversationChangedCtrl.stream;
  Stream<void> get friendshipStream => _friendshipCtrl.stream;

  bool get isLoggedIn => _loggedIn;
  String? get currentUserId => _imUserId;

  static bool get isPlatformSupported => true;

  Future<void> init() async {
    if (_initialized) return;
    await _bridge.init({
      'coreWasmPath': 'openIM.wasm',
      'sqlWasmPath': 'sql-wasm.wasm',
      'debug': kDebugMode,
    });
    _bindListeners();
    _initialized = true;
  }

  void _bindListeners() {
    void on(String event, void Function(Object? payload) handler) {
      _bridge.on(event, handler);
    }

    on('connecting', (_) {
      debugPrint('[IM_WEB] 连接中...');
      connectionNotifier.value = false;
    });
    on('connectSuccess', (_) {
      debugPrint('[IM_WEB] 连接成功');
      connectionNotifier.value = true;
    });
    on('connectFailed', (payload) {
      debugPrint('[IM_WEB] 连接失败: $payload');
      connectionNotifier.value = false;
    });
    on('tokenExpired', (_) => _refreshIMToken());
    on('tokenInvalid', (_) {
      _loggedIn = false;
      connectionNotifier.value = false;
    });
    on('kickedOffline', (_) {
      _loggedIn = false;
      connectionNotifier.value = false;
    });
    on('unreadChanged', (payload) {
      unreadCountNotifier.value = _toInt(payload);
    });
    on('conversationChanged', (_) {
      _conversationChangedCtrl.add(null);
      _updateUnreadCount();
    });
    on('friendshipChanged', (_) {
      _friendshipCtrl.add(null);
    });
    on('newMessages', (payload) {
      final list = _asList(payload);
      for (final item in list) {
        final map = _messageToMap(_asMap(item));
        _newMessageCtrl.add(map);
      }
      _conversationChangedCtrl.add(null);
      _updateUnreadCount();
    });
  }

  Future<bool> login() async {
    if (_loggedIn) return true;
    if (_loginInFlight != null) return _loginInFlight!;
    _loginInFlight = _doLogin();
    try {
      return await _loginInFlight!;
    } finally {
      _loginInFlight = null;
    }
  }

  Future<bool> _doLogin() async {
    try {
      await init();
      await _ensureCredentials();
      if (_imToken == null || _imUserId == null) return false;

      await _callAsync('login', {
        'userID': _imUserId,
        'token': _imToken,
        'platformID': 5,
        'apiAddr': _apiUrl ?? AppConfig.imApiUrl,
        'wsAddr': _wsUrl ?? AppConfig.imWsUrl,
        'debug': kDebugMode,
      });
      _loggedIn = true;
      connectionNotifier.value = true;
      await _saveCredentials();
      await _updateUnreadCount();
      debugPrint('[IM_WEB] login ok user=$_imUserId');
      return true;
    } catch (e) {
      debugPrint('[IM_WEB] login failed: $e');
      _loggedIn = false;
      connectionNotifier.value = false;
      return false;
    }
  }

  Future<bool> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _imToken = prefs.getString(_imTokenKey);
    _imUserId = prefs.getString(_imUserIdKey);
    _wsUrl = prefs.getString(_imWsUrlKey);
    _apiUrl = prefs.getString(_imApiUrlKey);
    if (_imToken == null || _imUserId == null) return false;
    return login();
  }

  Future<void> logout() async {
    try {
      if (_initialized) await _callAsync('logout');
    } catch (e) {
      debugPrint('[IM_WEB] logout failed: $e');
    }
    _loggedIn = false;
    connectionNotifier.value = false;
    unreadCountNotifier.value = 0;
    await _clearCredentials();
  }

  Future<void> _ensureCredentials({bool forceRefresh = false}) async {
    if (!forceRefresh && _imToken != null && _imUserId != null) return;
    final token = AuthService.token;
    if (token == null) throw Exception(T.current.chatErrPleaseLogin);

    Future<http.Response> request(String bearer) {
      return http
          .post(
            Uri.parse('$_backendUrl/api/im/token'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $bearer',
            },
            body: json.encode({'platform': 5}),
          )
          .timeout(const Duration(seconds: 12));
    }

    var resp = await request(token);
    if (resp.statusCode == 401) {
      await AuthService.refreshSession();
      final newToken = AuthService.token;
      if (newToken == null) throw Exception(T.current.chatErrPleaseLogin);
      resp = await request(newToken);
    }
    if (resp.statusCode != 200) {
      throw Exception('IM token HTTP ${resp.statusCode}: ${resp.body}');
    }
    final data = json.decode(resp.body) as Map<String, dynamic>;
    _imUserId = data['im_user_id']?.toString();
    _imToken = data['im_token']?.toString();
    _wsUrl = data['ws_url']?.toString();
    _apiUrl = data['api_url']?.toString();
    await _saveCredentials();
  }

  Future<void> _refreshIMToken() async {
    try {
      await _ensureCredentials(forceRefresh: true);
      _loggedIn = false;
      await login();
    } catch (e) {
      debugPrint('[IM_WEB] refresh token failed: $e');
    }
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
    _imToken = null;
    _imUserId = null;
    _wsUrl = null;
    _apiUrl = null;
  }

  Future<List<Map<String, dynamic>>> searchUsers(String q) async {
    if (q.trim().length < 2) return const [];
    try {
      final resp = await http
          .get(
            Uri.parse(
              '$_backendUrl/api/im/users/search?q=${Uri.encodeQueryComponent(q.trim())}',
            ),
            headers: {'Authorization': 'Bearer ${AuthService.token}'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint(
          '[IM_WEB] searchUsers failed ${resp.statusCode}: ${resp.body}',
        );
        return const [];
      }
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return List<Map<String, dynamic>>.from(data['users'] ?? const []);
    } catch (e) {
      debugPrint('[IM_WEB] searchUsers error: $e');
      return const [];
    }
  }

  Future<bool> sendFriendApplication({
    required String userID,
    String reqMsg = '',
  }) async {
    await login();
    try {
      await _callAsync('addFriend', {'toUserID': userID, 'reqMsg': reqMsg});
      return true;
    } catch (e) {
      if (_isAlreadyFriendsError(e)) {
        debugPrint(
          '[IM_WEB] friend relation already exists, treat as ok: $userID',
        );
        return true;
      }
      debugPrint('[IM_WEB] addFriend failed: $e');
      return false;
    }
  }

  Future<bool> acceptFriendApplication({
    required String fromUserID,
    String handleMsg = '',
  }) async {
    await login();
    try {
      await _callAsync('acceptFriendApplication', {
        'toUserID': fromUserID,
        'handleMsg': handleMsg,
      });
      return true;
    } catch (e) {
      debugPrint('[IM_WEB] accept friend failed: $e');
      return false;
    }
  }

  Future<bool> rejectFriendApplication({
    required String fromUserID,
    String handleMsg = '',
  }) async {
    await login();
    try {
      await _callAsync('refuseFriendApplication', {
        'toUserID': fromUserID,
        'handleMsg': handleMsg,
      });
      return true;
    } catch (e) {
      debugPrint('[IM_WEB] reject friend failed: $e');
      return false;
    }
  }

  Future<void> markConversationRead({required String conversationID}) async {
    await login();
    try {
      await _callAsync('markConversationMessageAsRead', conversationID);
      await _updateUnreadCount();
    } catch (e) {
      debugPrint('[IM_WEB] mark read failed: $e');
    }
  }

  Future<Map<String, Map<String, dynamic>>> lookupUsersFromSupabase(
    List<String> userIDList,
  ) async {
    final ids = userIDList.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const {};
    final result = <String, Map<String, dynamic>>{};
    try {
      final token = AuthService.token;
      final uri = Uri.parse(
        '$_backendUrl/api/im/users/profiles',
      ).replace(queryParameters: {'ids': ids.join(',')});
      final resp = await http
          .get(
            uri,
            headers: token == null ? null : {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        for (final raw in List<Map<String, dynamic>>.from(
          data['users'] ?? const [],
        )) {
          final id = raw['im_user_id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final face =
              raw['face_url']?.toString() ??
              raw['avatar_url']?.toString() ??
              '';
          result[id] = {
            'im_user_id': id,
            'nickname': raw['nickname']?.toString() ?? '',
            'email': raw['email']?.toString() ?? '',
            'face_url': face,
            'avatar_url': face,
          };
        }
      } else {
        debugPrint(
          '[IM_WEB] profiles lookup failed ${resp.statusCode}: ${resp.body}',
        );
      }
    } catch (e) {
      debugPrint('[IM_WEB] profiles lookup exception: $e');
    }

    final missingIds = ids.where((id) => !result.containsKey(id)).toList();
    if (missingIds.isEmpty) return result;

    for (final id in missingIds) {
      try {
        final hits = await searchUsers(id);
        for (final user in hits) {
          if ((user['im_user_id']?.toString() ?? '') == id) {
            result[id] = user;
            break;
          }
        }
      } catch (e) {
        debugPrint('[IM_WEB] supabase lookup failed user=$id: $e');
      }
    }
    return result;
  }

  Future<Set<String>> getFriendIds() async {
    final friends = await getFriendListAsMaps();
    return friends
        .map((f) => f['user_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<List<Map<String, dynamic>>> getFriendListAsMaps() async {
    await login();
    final list = _asList(await _callAsync('getFriendList'));
    final local = list.map((item) => _friendInfoToMap(_asMap(item))).toList();
    final server = await _fetchServerFriendListAsMaps();
    return _mergeFriendMaps(local, server);
  }

  Future<List<Map<String, dynamic>>>
  getIncomingFriendApplicationsAsMaps() async {
    await login();
    final list = _asList(
      await _callAsync('getFriendApplicationListAsRecipient'),
    );
    return list.map((item) => _friendApplicationToMap(_asMap(item))).toList();
  }

  Future<List<Map<String, dynamic>>> getConversationListAsMaps() async {
    await login();
    final list = _asList(await _callAsync('getAllConversationList'));
    return list.map((item) => _conversationToMap(_asMap(item))).toList();
  }

  Future<int> getTotalUnread() async {
    await login();
    return _toInt(await _callAsync('getTotalUnreadMsgCount'));
  }

  Future<List<Map<String, dynamic>>> getHistoryMessagesAsMaps({
    required String conversationID,
    int count = 30,
  }) async {
    await login();
    final list = _asList(
      await _callAsync('getAdvancedHistoryMessageList', {
        'conversationID': conversationID,
        'startClientMsgID': '',
        'count': count,
        'viewType': 0,
      }),
    );
    return list.map((item) => _messageToMap(_asMap(item))).toList();
  }

  Future<Map<String, dynamic>?> sendTextMessageAsMap({
    required String conversationID,
    required String text,
    required String userID,
    String? groupID,
    int conversationType = 1,
  }) async {
    await login();
    final sent = await _callAsync('sendTextMessage', {
      'conversationID': conversationID,
      'conversationType': conversationType,
      'userID': userID,
      'groupID': groupID ?? '',
      'text': text,
      'title': 'MyApp',
    });
    return _messageToMap(_asMap(sent));
  }

  Future<Map<String, dynamic>?> sendImageByUrlAsMap({
    required String conversationID,
    required String url,
    required String sourcePath,
    required String uuid,
    required int width,
    required int height,
    required int size,
    String? thumbUrl,
    required String userID,
    String? groupID,
    int conversationType = 1,
  }) async {
    await login();
    final sent = await _callAsync('sendImageByUrl', {
      'conversationID': conversationID,
      'conversationType': conversationType,
      'userID': userID,
      'groupID': groupID ?? '',
      'url': url,
      'thumbUrl': thumbUrl ?? url,
      'sourcePath': sourcePath,
      'uuid': uuid,
      'width': width,
      'height': height,
      'size': size,
      'title': T.current.imPushNewMessage,
    });
    return _messageToMap(_asMap(sent));
  }

  Future<Map<String, dynamic>?> sendVideoByUrlAsMap({
    required String conversationID,
    required String videoUrl,
    required String videoSourcePath,
    required String videoUuid,
    required String videoType,
    required int videoSize,
    required int duration,
    String snapshotUrl = '',
    String snapshotSourcePath = '',
    String snapshotUuid = '',
    int snapshotSize = 0,
    int snapshotWidth = 0,
    int snapshotHeight = 0,
    required String userID,
    String? groupID,
    int conversationType = 1,
  }) async {
    await login();
    final sent = await _callAsync('sendVideoByUrl', {
      'conversationID': conversationID,
      'conversationType': conversationType,
      'userID': userID,
      'groupID': groupID ?? '',
      'videoUrl': videoUrl,
      'videoSourcePath': videoSourcePath,
      'videoUuid': videoUuid,
      'videoType': videoType,
      'videoSize': videoSize,
      'duration': duration,
      'snapshotUrl': snapshotUrl,
      'snapshotSourcePath': snapshotSourcePath,
      'snapshotUuid': snapshotUuid,
      'snapshotSize': snapshotSize,
      'snapshotWidth': snapshotWidth,
      'snapshotHeight': snapshotHeight,
      'title': T.current.imPushNewMessage,
    });
    return _messageToMap(_asMap(sent));
  }

  Future<Object?> _callAsync(String method, [Object? arg]) async {
    return _bridge.callAsync(method, arg);
  }

  List<Object?> _asList(Object? value) {
    if (value is List) return value.cast<Object?>();
    return const [];
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return const {};
  }

  int _toInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  Future<void> _updateUnreadCount() async {
    try {
      unreadCountNotifier.value = await getTotalUnread();
    } catch (_) {}
  }

  Map<String, dynamic> _friendInfoToMap(Map<String, dynamic> f) => {
    'user_id': f['userID']?.toString() ?? '',
    'nickname': f['nickname']?.toString() ?? '',
    'face_url': f['faceURL']?.toString() ?? '',
    'remark': f['remark']?.toString() ?? '',
  };

  Future<List<Map<String, dynamic>>> _fetchServerFriendListAsMaps() async {
    try {
      final token = AuthService.token;
      if (token == null || token.isEmpty) return const [];
      final resp = await http
          .get(
            Uri.parse('$_backendUrl/api/im/friends'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint(
          '[IM_WEB] server friend list failed ${resp.statusCode}: ${resp.body}',
        );
        return const [];
      }

      final data = json.decode(resp.body);
      if (data is! Map<String, dynamic>) return const [];
      final rawFriends = data['friends'];
      if (rawFriends is! List) return const [];

      final friends = <Map<String, dynamic>>[];
      for (final raw in rawFriends) {
        if (raw is! Map) continue;
        final map = _asMap(raw);
        final id =
            map['user_id']?.toString() ?? map['im_user_id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final face =
            map['face_url']?.toString() ?? map['avatar_url']?.toString() ?? '';
        friends.add({
          'user_id': id,
          'nickname': map['nickname']?.toString() ?? '',
          'face_url': face,
          'avatar_url': face,
          'remark': map['remark']?.toString() ?? '',
          'email': map['email']?.toString() ?? '',
          'source': map['source']?.toString() ?? 'server',
        });
      }
      return friends;
    } catch (e) {
      debugPrint('[IM_WEB] server friend list exception: $e');
      return const [];
    }
  }

  List<Map<String, dynamic>> _mergeFriendMaps(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> server,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final item in [...local, ...server]) {
      final id = item['user_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final prev = byId[id];
      if (prev == null) {
        byId[id] = Map<String, dynamic>.from(item);
        continue;
      }
      final merged = Map<String, dynamic>.from(prev);
      for (final entry in item.entries) {
        final value = entry.value;
        if (value != null && value.toString().isNotEmpty) {
          merged[entry.key] = value;
        }
      }
      byId[id] = merged;
    }
    final result = byId.values.toList();
    result.sort((a, b) {
      final an =
          ((a['remark']?.toString().isNotEmpty == true)
                  ? a['remark']
                  : a['nickname'])
              ?.toString()
              .toLowerCase();
      final bn =
          ((b['remark']?.toString().isNotEmpty == true)
                  ? b['remark']
                  : b['nickname'])
              ?.toString()
              .toLowerCase();
      return (an ?? '').compareTo(bn ?? '');
    });
    return result;
  }

  bool _isAlreadyFriendsError(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('1304') ||
        text.contains('relationshipalreadyerror') ||
        text.contains('already friends');
  }

  Map<String, dynamic> _friendApplicationToMap(Map<String, dynamic> a) => {
    'from_user_id': a['fromUserID']?.toString() ?? '',
    'from_nickname': a['fromNickname']?.toString() ?? '',
    'from_face_url': a['fromFaceURL']?.toString() ?? '',
    'req_msg': a['reqMsg']?.toString() ?? '',
    'handle_result': _toInt(a['handleResult']),
    'create_time': _toInt(a['createTime']),
  };

  Map<String, dynamic> _messageToMap(Map<String, dynamic> m) {
    final contentType = _toInt(m['contentType']);
    final content = _messageContentMap(m);
    final pictureElem = _firstMap([
      m['pictureElem'],
      content['pictureElem'],
      _looksLikePictureElem(content) ? content : null,
    ]);
    final bigPicture = _asMap(pictureElem['bigPicture']);
    final sourcePicture = _asMap(pictureElem['sourcePicture']);
    final snapshotPicture = _asMap(pictureElem['snapshotPicture']);
    final videoElem = _firstMap([
      m['videoElem'],
      content['videoElem'],
      _looksLikeVideoElem(content) ? content : null,
    ]);
    final fileElem = _firstMap([
      m['fileElem'],
      content['fileElem'],
      _looksLikeFileElem(content) ? content : null,
    ]);
    final soundElem = _firstMap([
      m['soundElem'],
      content['soundElem'],
      _looksLikeSoundElem(content) ? content : null,
    ]);
    final imageUrl = _firstNonEmpty([
      bigPicture['url'],
      sourcePicture['url'],
      snapshotPicture['url'],
    ]);
    final imageThumbUrl = _firstNonEmpty([
      snapshotPicture['url'],
      sourcePicture['url'],
      bigPicture['url'],
    ]);
    String text;
    if (contentType == 101) {
      final textElem = _asMap(m['textElem']);
      text = textElem['content']?.toString() ?? '';
      if (text.isEmpty) {
        text = content['content']?.toString() ?? m['content']?.toString() ?? '';
      }
    } else {
      text = switch (contentType) {
        102 => '[图片]',
        103 => '[语音]',
        104 => '[视频]',
        105 => '[文件]',
        _ => '[消息]',
      };
    }
    final sendId = m['sendID']?.toString() ?? '';
    final isMe = sendId == currentUserId && sendId.isNotEmpty;
    final sendTime = _toInt(m['sendTime'] ?? m['createTime']);
    final senderNick = m['senderNickname']?.toString() ?? '';
    return {
      'client_msg_id': m['clientMsgID']?.toString() ?? '',
      'send_id': sendId,
      'recv_id': m['recvID']?.toString() ?? '',
      'send_time': sendTime,
      'content_type': contentType,
      'text': text,
      'sender_nickname': senderNick,
      'sender_face_url': m['senderFaceUrl']?.toString() ?? '',
      'is_me': isMe,
      'is_other': !isMe,
      'display_time': _formatChatTime(sendTime),
      'display_sender': isMe
          ? T.current.imSenderMe
          : (senderNick.isNotEmpty ? senderNick : sendId),
      'bubble_color': isMe ? '#95EC69' : '#FFFFFF',
      'bubble_text_color': '#000000',
      'image_url': imageUrl,
      'image_thumb_url': imageThumbUrl,
      'video_url': videoElem['videoUrl']?.toString() ?? '',
      'video_snapshot_url': videoElem['snapshotUrl']?.toString() ?? '',
      'video_duration': _toInt(videoElem['duration']),
      'file_url': fileElem['sourceUrl']?.toString() ?? '',
      'file_name': fileElem['fileName']?.toString() ?? '',
      'file_size': _toInt(fileElem['fileSize']),
      'sound_url': soundElem['sourceUrl']?.toString() ?? '',
      'sound_duration': _toInt(soundElem['duration']),
    };
  }

  String _firstNonEmpty(List<Object?> values) {
    for (final value in values) {
      final text = value?.toString() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  Map<String, dynamic> _messageContentMap(Map<String, dynamic> m) {
    final raw = m['content'];
    if (raw is Map) return _asMap(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        return _asMap(decoded);
      } catch (_) {}
    }
    return const {};
  }

  Map<String, dynamic> _firstMap(List<Object?> values) {
    for (final value in values) {
      final map = _asMap(value);
      if (map.isNotEmpty) return map;
    }
    return const {};
  }

  bool _looksLikePictureElem(Map<String, dynamic> value) {
    return value.containsKey('sourcePicture') ||
        value.containsKey('bigPicture') ||
        value.containsKey('snapshotPicture');
  }

  bool _looksLikeVideoElem(Map<String, dynamic> value) {
    return value.containsKey('videoUrl') || value.containsKey('snapshotUrl');
  }

  bool _looksLikeFileElem(Map<String, dynamic> value) {
    return value.containsKey('sourceUrl') && value.containsKey('fileName');
  }

  bool _looksLikeSoundElem(Map<String, dynamic> value) {
    return value.containsKey('sourceUrl') && value.containsKey('duration');
  }

  Map<String, dynamic> _conversationToMap(Map<String, dynamic> c) {
    final latestRaw = c['latestMsg'];
    Map<String, dynamic> latestMsg = const {};
    if (latestRaw is String && latestRaw.isNotEmpty) {
      try {
        latestMsg = Map<String, dynamic>.from(json.decode(latestRaw) as Map);
      } catch (_) {}
    } else {
      latestMsg = _asMap(latestRaw);
    }
    final latestText = latestMsg.isEmpty
        ? ''
        : _messageToMap(latestMsg)['text'] as String? ?? '';
    final latestTime = _toInt(c['latestMsgSendTime']);
    final unread = _toInt(c['unreadCount']);
    return {
      'conversation_id': c['conversationID']?.toString() ?? '',
      'conversation_type': _toInt(c['conversationType']),
      'user_id': c['userID']?.toString() ?? '',
      'group_id': c['groupID']?.toString() ?? '',
      'show_name': c['showName']?.toString() ?? '',
      'face_url': c['faceURL']?.toString() ?? '',
      'latest_text': latestText,
      'latest_time': latestTime,
      'unread_count': unread,
      'display_unread': unread > 0 ? unread.toString() : '',
      'display_time': _formatChatTime(latestTime),
    };
  }

  String _formatChatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dtDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(dtDay).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    if (diff <= 0) return '${two(dt.hour)}:${two(dt.minute)}';
    if (diff == 1) return T.current.relativeDateYesterday;
    if (diff < 7) return '$diff天前';
    return '${two(dt.month)}-${two(dt.day)}';
  }
}
