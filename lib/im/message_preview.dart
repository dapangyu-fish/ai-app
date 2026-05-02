// IM 消息类型 → 一行预览 / 系统通知文案
// ─────────────────────────────────────────────────────────
// 给 conversation_list（最近一条预览）和 chat_page（系统通知行）共用。
//
// OpenIM contentType 文档：
//   101-117  普通消息（text / picture / voice / video / file / @ / merger / card / location / custom / typing / quote / customFace / advancedText）
//   1000+    各种 notification（加好友 / 群组变更 / 撤回 / OA 等）
//   2101     撤回消息

import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';

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
  switch (msg.contentType) {
    case MessageType.text:
      return msg.textElem?.content ?? '';
    case MessageType.atText:
      return msg.atTextElem?.text ?? '[@消息]';
    case MessageType.picture:
      return '[图片]';
    case MessageType.voice:
      return '[语音]';
    case MessageType.video:
      return '[视频]';
    case MessageType.file:
      final name = msg.fileElem?.fileName;
      return name?.isNotEmpty == true ? '[文件] $name' : '[文件]';
    case MessageType.location:
      return '[位置]';
    case MessageType.card:
      return '[名片]';
    case MessageType.merger:
      return '[聊天记录]';
    case MessageType.quote:
      return msg.quoteElem?.text ?? '[引用]';
    case MessageType.customFace:
      return '[表情]';
    case MessageType.advancedText:
      return msg.advancedTextElem?.text ?? '[富文本]';
    case MessageType.custom:
      return '[自定义消息]';
    default:
      return _systemMessageText(msg);
  }
}

/// 聊天页正中央展示的系统通知文案
String systemMessageDisplay(Message msg) => _systemMessageText(msg);

String _systemMessageText(Message msg) {
  switch (msg.contentType) {
    // ── 好友相关 ──
    case MessageType.friendApplicationApprovedNotification:
      return '对方同意了你的好友申请';
    case MessageType.friendApplicationRejectedNotification:
      return '对方拒绝了你的好友申请';
    case MessageType.friendApplicationNotification:
      return '收到一条好友申请';
    case MessageType.friendAddedNotification:
      return '你们已经是好友了，可以聊天了';
    case MessageType.friendDeletedNotification:
      return '你们的好友关系已解除';
    case MessageType.friendRemarkSetNotification:
      return '好友备注已修改';
    case MessageType.blackAddedNotification:
      return '已加入黑名单';
    case MessageType.blackDeletedNotification:
      return '已移出黑名单';

    // ── 群组相关 ──
    case MessageType.groupCreatedNotification:
      return '群聊已创建';
    case MessageType.groupInfoSetNotification:
      return '群信息已修改';
    case MessageType.groupInfoSetNameNotification:
      return '群名已修改';
    case MessageType.groupInfoSetAnnouncementNotification:
      return '群公告已更新';
    case MessageType.joinGroupApplicationNotification:
      return '收到一条入群申请';
    case MessageType.memberQuitNotification:
      return '有成员退出群聊';
    case MessageType.memberKickedNotification:
      return '有成员被移出群聊';
    case MessageType.memberInvitedNotification:
      return '有成员被邀请入群';
    case MessageType.memberEnterNotification:
      return '有成员加入群聊';
    case MessageType.dismissGroupNotification:
      return '群聊已解散';
    case MessageType.groupOwnerTransferredNotification:
      return '群主已转让';
    case MessageType.groupApplicationAcceptedNotification:
      return '入群申请已通过';
    case MessageType.groupApplicationRejectedNotification:
      return '入群申请已被拒绝';
    case MessageType.groupMemberMutedNotification:
      return '成员被禁言';
    case MessageType.groupMemberCancelMutedNotification:
      return '成员禁言已解除';
    case MessageType.groupMutedNotification:
      return '全员禁言';
    case MessageType.groupCancelMutedNotification:
      return '全员禁言已解除';
    case MessageType.groupMemberInfoChangedNotification:
      return '成员信息变更';
    case MessageType.groupMemberSetToAdminNotification:
      return '成员被设为管理员';
    case MessageType.groupMemberSetToOrdinaryUserNotification:
      return '管理员已恢复为普通成员';

    // ── 用户相关 ──
    case MessageType.userInfoUpdatedNotification:
      return '用户资料已更新';
    case MessageType.conversationChangeNotification:
      return '会话已变更';

    // ── 其它 ──
    case MessageType.revokeMessageNotification:
      return '撤回了一条消息';
    case MessageType.oaNotification:
      return '[OA 通知]';
    case MessageType.businessNotification:
      return '[系统通知]';
    case MessageType.burnAfterReadingNotification:
      return '[阅后即焚]';

    default:
      return '[未知消息: ${msg.contentType}]';
  }
}
