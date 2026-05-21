import 'dart:async';
import 'package:flutter/foundation.dart';

/// IMService 的 web stub。
///
/// flutter_openim_sdk 没有 web 实现，web 上 IM 功能整体不可用。这里提供与
/// im_service_io.dart 公共 API 同名的最小实现（仅覆盖 main / interpreter /
/// local_data_wiper 在 web 上会触达的成员），全部 no-op，让 web 能编译且不崩。
///
/// 注意：聊天 UI（conversation_list / chat_page 等）在 web 上已由调用方剪枝，
/// 不会编译进来，所以这里**不需要**实现那些 typed（OpenIM 类型）方法。
class IMService {
  static final IMService _instance = IMService._();
  static IMService get instance => _instance;
  IMService._();

  final ValueNotifier<bool> connectionNotifier = ValueNotifier(false);
  final ValueNotifier<int> unreadCountNotifier = ValueNotifier(0);

  bool get isLoggedIn => false;
  String? get currentUserId => null;

  /// web 不支持 IM。
  static bool get isPlatformSupported => false;

  Future<bool> login() async => false;
  Future<void> logout() async {}
  Future<bool> restoreSession() async => false;

  Future<List<Map<String, dynamic>>> searchUsers(String q) async => const [];

  Future<bool> sendFriendApplication({
    required String userID,
    String reqMsg = '',
  }) async =>
      false;

  Future<bool> acceptFriendApplication({
    required String fromUserID,
    String handleMsg = '',
  }) async =>
      false;

  Future<bool> rejectFriendApplication({
    required String fromUserID,
    String handleMsg = '',
  }) async =>
      false;

  Future<void> markConversationRead({required String conversationID}) async {}

  Future<Map<String, Map<String, dynamic>>> lookupUsersFromSupabase(
          List<String> userIDList) async =>
      const {};

  // ── JSON-DSL 桥接（与 io 版同名，返回空）──
  Future<Set<String>> getFriendIds() async => const {};
  Future<List<Map<String, dynamic>>> getFriendListAsMaps() async => const [];
  Future<List<Map<String, dynamic>>> getIncomingFriendApplicationsAsMaps() async =>
      const [];
  Future<List<Map<String, dynamic>>> getConversationListAsMaps() async => const [];
  Future<int> getTotalUnread() async => 0;
  Future<List<Map<String, dynamic>>> getHistoryMessagesAsMaps({
    required String conversationID,
    int count = 30,
  }) async =>
      const [];
  Future<Map<String, dynamic>?> sendTextMessageAsMap({
    required String conversationID,
    required String text,
    required String userID,
  }) async =>
      null;

  Stream<Map<String, dynamic>> get newMessageMapStream =>
      const Stream<Map<String, dynamic>>.empty();
}
