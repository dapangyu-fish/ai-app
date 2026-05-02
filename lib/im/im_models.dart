import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';

/// IM 连接状态
enum IMConnectionState {
  disconnected,
  connecting,
  connected,
  tokenExpired,
  kickedOffline,
}

/// 消息发送状态
enum MessageSendState {
  sending,
  success,
  failed,
}

/// 会话摘要 — 用于会话列表展示
class ConversationSummary {
  final String conversationID;
  final String name;
  final String? faceURL;
  final String lastMessage;
  final int lastMessageTime;
  final int unreadCount;
  final bool isPinned;
  final int conversationType; // 1=单聊, 3=群聊

  ConversationSummary({
    required this.conversationID,
    required this.name,
    this.faceURL,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.unreadCount,
    required this.isPinned,
    required this.conversationType,
  });

  factory ConversationSummary.fromConversationInfo(ConversationInfo info) {
    return ConversationSummary(
      conversationID: info.conversationID,
      name: info.showName ?? '未知',
      faceURL: info.faceURL,
      lastMessage: _extractLastMessage(info.latestMsg),
      lastMessageTime: info.latestMsgSendTime ?? 0,
      unreadCount: info.unreadCount,
      isPinned: info.isPinned ?? false,
      conversationType: info.conversationType ?? 1,
    );
  }

  static String _extractLastMessage(Message? msg) {
    if (msg == null) return '';
    switch (msg.contentType) {
      case MessageType.text:
        return msg.textElem?.content ?? '';
      case MessageType.picture:
        return '[图片]';
      case MessageType.video:
        return '[视频]';
      case MessageType.voice:
        return '[语音]';
      case MessageType.file:
        return '[文件]';
      case MessageType.location:
        return '[位置]';
      case MessageType.revokeMessageNotification:
        return '撤回了一条消息';
      default:
        return '[消息]';
    }
  }
}

/// 聊天消息 UI 模型
class ChatMessage {
  final Message raw;
  final bool isMe;
  final MessageSendState sendState;

  ChatMessage({
    required this.raw,
    required this.isMe,
    this.sendState = MessageSendState.success,
  });

  String get senderName => raw.senderNickname ?? '';
  String? get senderFaceUrl => raw.senderFaceUrl;
  int? get sendTime => raw.sendTime;
  String? get clientMsgID => raw.clientMsgID;
  int? get contentType => raw.contentType;
  bool get isRead => raw.isRead ?? false;
}

/// 群成员简要信息
class GroupMemberSummary {
  final String userID;
  final String nickname;
  final String? faceURL;
  final int role; // 1=普通, 2=管理员, 3=群主

  GroupMemberSummary({
    required this.userID,
    required this.nickname,
    this.faceURL,
    required this.role,
  });

  factory GroupMemberSummary.fromGroupMembersInfo(GroupMembersInfo info) {
    return GroupMemberSummary(
      userID: info.userID ?? '',
      nickname: info.nickname ?? '',
      faceURL: info.faceURL,
      role: info.roleLevel ?? 1,
    );
  }
}
