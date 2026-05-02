// IM 消息类型 → 一行预览 / 系统通知文案
// ─────────────────────────────────────────────────────────
// 给 conversation_list（最近一条预览）和 chat_page（系统通知行）共用。
//
// OpenIM contentType 文档：
//   101-117  普通消息（text / picture / voice / video / file / @ / merger / card / location / custom / typing / quote / customFace / advancedText）
//   1000+    各种 notification（加好友 / 群组变更 / 撤回 / OA 等）
//   2101     撤回消息
//
// i18n: 这些函数是纯函数（无 BuildContext），所以走 T.current 拿当前 locale 的字符串。

import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import '../i18n/framework_strings.dart';

/// 是否是"系统通知"类型 —— 在聊天页里应当以居中灰文形式展示，不带气泡
bool isSystemNotification(int? contentType) {
  if (contentType == null) return false;
  // OpenIM notificationBegin=1000 / notificationEnd=2000；2101=撤回也算系统消息
  return (contentType >= 1000 && contentType < 2000) ||
      contentType == MessageType.revokeMessageNotification ||
      contentType == MessageType.businessNotification;
}

/// 单行预览（会话列表 / 通知 banner / 引用消息）
/// 系统通知也走这里 —— 文案与聊天页一致
String previewMessage(Message? msg) {
  if (msg == null) return '';
  final s = T.current;
  switch (msg.contentType) {
    case MessageType.text:
      return msg.textElem?.content ?? '';
    case MessageType.atText:
      return msg.atTextElem?.text ?? s.imPreviewAtFallback;
    case MessageType.picture:
      return s.imPreviewImage;
    case MessageType.voice:
      return s.imPreviewVoice;
    case MessageType.video:
      return s.imPreviewVideo;
    case MessageType.file:
      final name = msg.fileElem?.fileName;
      return name?.isNotEmpty == true
          ? T.fmt(s.imPreviewFileWithName, {'name': name})
          : s.imPreviewFile;
    case MessageType.location:
      return s.imPreviewLocation;
    case MessageType.card:
      return s.imPreviewCard;
    case MessageType.merger:
      return s.imPreviewMerger;
    case MessageType.quote:
      return msg.quoteElem?.text ?? s.imPreviewQuoteFallback;
    case MessageType.customFace:
      return s.imPreviewEmoji;
    case MessageType.advancedText:
      return msg.advancedTextElem?.text ?? s.imPreviewRichTextFallback;
    case MessageType.custom:
      return s.imPreviewCustom;
    default:
      return _systemMessageText(msg);
  }
}

/// 聊天页正中央展示的系统通知文案
String systemMessageDisplay(Message msg) => _systemMessageText(msg);

String _systemMessageText(Message msg) {
  final s = T.current;
  switch (msg.contentType) {
    // ── 好友相关 ──
    case MessageType.friendApplicationApprovedNotification:
      return s.imSysFriendApplyAccepted;
    case MessageType.friendApplicationRejectedNotification:
      return s.imSysFriendApplyRejected;
    case MessageType.friendApplicationNotification:
      return s.imSysFriendApplyReceived;
    case MessageType.friendAddedNotification:
      return s.imSysFriendAdded;
    case MessageType.friendDeletedNotification:
      return s.imSysFriendDeleted;
    case MessageType.friendRemarkSetNotification:
      return s.imSysFriendRemarkChanged;
    case MessageType.blackAddedNotification:
      return s.imSysFriendBlacklisted;
    case MessageType.blackDeletedNotification:
      return s.imSysFriendUnblacklisted;

    // ── 群组相关 ──
    case MessageType.groupCreatedNotification:
      return s.imSysGroupCreated;
    case MessageType.groupInfoSetNotification:
      return s.imSysGroupInfoChanged;
    case MessageType.groupInfoSetNameNotification:
      return s.imSysGroupNameChanged;
    case MessageType.groupInfoSetAnnouncementNotification:
      return s.imSysGroupNoticeUpdated;
    case MessageType.joinGroupApplicationNotification:
      return s.imSysGroupApplyReceived;
    case MessageType.memberQuitNotification:
      return s.imSysGroupMemberQuit;
    case MessageType.memberKickedNotification:
      return s.imSysGroupMemberKicked;
    case MessageType.memberInvitedNotification:
      return s.imSysGroupMemberInvited;
    case MessageType.memberEnterNotification:
      return s.imSysGroupMemberJoined;
    case MessageType.dismissGroupNotification:
      return s.imSysGroupDismissed;
    case MessageType.groupOwnerTransferredNotification:
      return s.imSysGroupOwnerTransferred;
    case MessageType.groupApplicationAcceptedNotification:
      return s.imSysGroupApplyApproved;
    case MessageType.groupApplicationRejectedNotification:
      return s.imSysGroupApplyRejected;
    case MessageType.groupMemberMutedNotification:
      return s.imSysGroupMemberMuted;
    case MessageType.groupMemberCancelMutedNotification:
      return s.imSysGroupMemberUnmuted;
    case MessageType.groupMutedNotification:
      return s.imSysGroupMutedAll;
    case MessageType.groupCancelMutedNotification:
      return s.imSysGroupUnmutedAll;
    case MessageType.groupMemberInfoChangedNotification:
      return s.imSysGroupMemberInfoChanged;
    case MessageType.groupMemberSetToAdminNotification:
      return s.imSysGroupMemberSetAdmin;
    case MessageType.groupMemberSetToOrdinaryUserNotification:
      return s.imSysGroupAdminRevoked;

    // ── 用户相关 ──
    case MessageType.userInfoUpdatedNotification:
      return s.imSysUserInfoUpdated;
    case MessageType.conversationChangeNotification:
      return s.imSysConversationChanged;

    // ── 其它 ──
    case MessageType.revokeMessageNotification:
      return s.imPreviewRevoked;
    case MessageType.oaNotification:
      return s.imPreviewOA;
    case MessageType.businessNotification:
      return s.imPreviewSystem;
    case MessageType.burnAfterReadingNotification:
      return s.imPreviewBurnAfterRead;

    default:
      return T.fmt(s.imPreviewUnknown, {'type': msg.contentType});
  }
}
