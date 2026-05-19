import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chewie/chewie.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../auth/auth_service.dart';
import '../i18n/framework_strings.dart';
import 'im_cache_manager.dart';
import 'im_media_uploader.dart';
import 'im_service.dart';
import 'group_management.dart';
import 'message_preview.dart';

/// 聊天页面 - 单聊/群聊消息界面
///
/// 注意：发送消息的 OpenIM SDK 需要 userID 或 groupID 作为收件人。
/// conversationID 仅用于标记会话（拉历史/已读/撤回）。如果只传 conversationID，
/// 消息会被以空收件人发送出去（旧 bug）。
class IMChatPage extends StatefulWidget {
  final String conversationID;
  final String conversationName;
  final String? faceURL;
  final int conversationType; // 1=单聊, 3=群聊
  // 收件人；单聊时填 userID，群聊时填 groupID。从 ConversationInfo 透传。
  final String? userID;
  final String? groupID;

  const IMChatPage({
    super.key,
    required this.conversationID,
    required this.conversationName,
    this.faceURL,
    this.conversationType = 1,
    this.userID,
    this.groupID,
  });

  @override
  State<IMChatPage> createState() => _IMChatPageState();
}

class _IMChatPageState extends State<IMChatPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  List<Message> _messages = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  StreamSubscription<Message>? _msgSub;
  StreamSubscription<RevokedInfo>? _revokedSub;
  StreamSubscription<List<ReadReceiptInfo>>? _receiptSub;

  // userId → face_url 缓存。
  // - 命中 String 值：用这个 URL
  // - 命中 null：查过了 Supabase 但没头像（避免重复查）
  // - 不在 map 里：还没查过
  // OpenIM 的 Message.senderFaceUrl 几乎永远是空（OpenIM 只在注册时写一次 faceURL，
  // 之后 Supabase 改头像不会回流），所以必须自己去 Supabase 拉真实头像。demo-im
  // JSON-APP 是用同样的 @im_get_user_info 内置函数实现的
  final Map<String, String?> _avatarCache = {};
  // 正在查的 userId，避免短时间内同一个 ID 被并发 lookup
  final Set<String> _avatarInFlight = {};

  @override
  void initState() {
    super.initState();
    _seedOwnAvatar();
    _loadMessages();
    _markRead();
    _subscribe();
    _scrollController.addListener(_onScroll);
  }

  /// 自己头像直接从 AuthService 取（已经在内存），不用走 Supabase 查
  void _seedOwnAvatar() {
    final myImId = IMService.instance.currentUserId;
    if (myImId == null) return;
    final myAvatar = AuthService.currentUser?['avatar_url']?.toString();
    _avatarCache[myImId] = (myAvatar != null && myAvatar.isNotEmpty) ? myAvatar : null;
  }

  /// 批量拉头像到 _avatarCache，重复 / in-flight 自动跳过。
  /// 调用方负责传入所有需要确保的 userIDs（一般是消息列表里所有 sendID）
  Future<void> _ensureAvatars(Iterable<String> userIds) async {
    final missing = userIds
        .where((id) => id.isNotEmpty &&
            !_avatarCache.containsKey(id) &&
            !_avatarInFlight.contains(id))
        .toSet();
    if (missing.isEmpty) return;
    _avatarInFlight.addAll(missing);
    try {
      final result = await IMService.instance
          .lookupUsersFromSupabase(missing.toList());
      if (!mounted) return;
      setState(() {
        for (final id in missing) {
          final face = result[id]?['face_url']?.toString();
          _avatarCache[id] = (face != null && face.isNotEmpty) ? face : null;
        }
      });
    } catch (e) {
      debugPrint('[ChatPage] lookup avatars failed: $e');
      // 失败也写 null 占位，防止无限重试。下次用户进出聊天页会重建 state 重试
      if (mounted) {
        setState(() {
          for (final id in missing) {
            _avatarCache.putIfAbsent(id, () => null);
          }
        });
      }
    } finally {
      _avatarInFlight.removeAll(missing);
    }
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _revokedSub?.cancel();
    _receiptSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 此消息属于当前 conversation 才处理（避免别的会话的新消息也插进来）
  bool _isForThisConversation(Message msg) {
    if (msg.contentType == null) return false;
    if (widget.conversationType == 1) {
      // 单聊：sendID 或 recvID 是对方
      final me = IMService.instance.currentUserId;
      final other = widget.userID;
      if (me == null || other == null) return false;
      return (msg.sendID == other && msg.recvID == me) ||
          (msg.sendID == me && msg.recvID == other);
    } else {
      // 群聊：groupID 匹配
      return widget.groupID != null && msg.groupID == widget.groupID;
    }
  }

  void _subscribe() {
    _msgSub = IMService.instance.newMessageStream.listen((msg) {
      if (!mounted || !_isForThisConversation(msg)) return;
      setState(() => _messages.insert(0, msg));
      _markRead();
      // 新消息发送者可能是没缓存过的（群聊新成员），按需补
      final sid = msg.sendID;
      if (sid != null && sid.isNotEmpty) {
        _ensureAvatars([sid]);
      }
    });
    _revokedSub = IMService.instance.revokedStream.listen((info) {
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.clientMsgID == info.clientMsgID);
      });
    });
    _receiptSub = IMService.instance.c2cReceiptStream.listen((receipts) {
      // OpenIM SDK 不会自动改本地内存里 Message.isRead，必须我们自己根据
      // ReadReceiptInfo.msgIDList 把对应消息标已读，UI 才会刷新（之前空 setState
      // 没用——msg.isRead 还是 false）。
      if (!mounted) return;
      final readIds = <String>{};
      for (final r in receipts) {
        // 只关心当前对话的 receipt（其他对话的别动）
        if (r.userID != null && r.userID != widget.userID) continue;
        for (final id in r.msgIDList ?? const <String>[]) {
          readIds.add(id);
        }
      }
      if (readIds.isEmpty) return;
      setState(() {
        for (var i = 0; i < _messages.length; i++) {
          final m = _messages[i];
          if (m.clientMsgID != null && readIds.contains(m.clientMsgID)) {
            m.isRead = true;
          }
        }
      });
    });
  }

  // OpenIM 的 getAdvancedHistoryMessageList 返的是升序（旧→新），
  // 我们 ListView 是 reverse:true（index=0 在底）+ 实时消息走 insert(0)，
  // 所以 _messages 必须是降序（newest at 0）才一致。
  Future<void> _loadMessages() async {
    setState(() => _loading = true);
    final messages = await IMService.instance.getHistoryMessages(
      conversationID: widget.conversationID,
      count: 20,
    );
    if (mounted) {
      setState(() {
        _messages = messages.reversed.toList();
        _loading = false;
        _hasMore = messages.length >= 20;
      });
      // 拉初始消息后，把所有出现过的 senderID 头像一次性预热
      _ensureAvatars(_messages.map((m) => m.sendID ?? ''));
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_loadingMore || !_hasMore || _messages.isEmpty) return;
    _loadingMore = true;

    // _messages.last = 当前 list 中最旧的一条（降序 list 的 last）
    // OpenIM 用 startMsg 做锚点取"它之前"的，仍然返升序，要再翻转
    final older = await IMService.instance.getHistoryMessages(
      conversationID: widget.conversationID,
      startMsg: _messages.last,
      count: 20,
    );

    if (mounted) {
      setState(() {
        _messages.addAll(older.reversed);
        _hasMore = older.length >= 20;
        _loadingMore = false;
      });
      // 翻历史可能引入新的 senderID（旧群成员），补头像
      _ensureAvatars(older.map((m) => m.sendID ?? ''));
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreMessages();
    }
  }

  Future<void> _markRead() async {
    await IMService.instance.markConversationRead(
      conversationID: widget.conversationID,
    );
  }

  /// 乐观 UI 发送文本：
  ///   1. create 拿到本地 Message（status=sending） → 立刻插 list 显示
  ///   2. 输入框清空，按钮立即可用，用户能继续敲下一条
  ///   3. 后台 sendMessage 不阻塞 UI；回来后按 clientMsgID 找到那条更新 status
  ///
  /// 这样网慢/丢包不会卡住输入区，符合主流 IM 的体验
  Future<void> _sendText() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();
    final pending = await IMService.instance.createTextMessage(text);

    if (mounted) {
      setState(() => _messages.insert(0, pending));
    }

    // 后台发，不阻塞 UI
    unawaited(IMService.instance.sendPreparedMessage(
      message: pending,
      previewText: text,
      userID: widget.userID,
      groupID: widget.groupID,
    ).then((sent) {
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m.clientMsgID == pending.clientMsgID);
        if (idx < 0) return;
        if (sent != null) {
          // SDK 把状态改成 sendSuccess，且可能补 serverMsgID
          _messages[idx] = sent;
        } else {
          // 发送失败：把本地这条标记为 failed（SDK 会改 pending.status 但保险显式改）
          pending.status = MessageStatus.failed;
          _messages[idx] = pending;
        }
      });
    }));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(
              widget.conversationName,
              style: const TextStyle(fontSize: 16),
            ),
            if (widget.conversationType == 3)
              Text(
                s.imGroupChat,
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
          ],
        ),
        centerTitle: true,
        actions: [
          if (widget.conversationType == 3)
            IconButton(
              icon: const Icon(Icons.group),
              onPressed: _showGroupInfo,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList(cs)),
          _buildInputBar(cs),
        ],
      ),
    );
  }

  Widget _buildMessageList(ColorScheme cs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_messages.isEmpty) {
      return Center(
        child: Text(T.of(context).imEmptyMessages, style: TextStyle(color: cs.outline)),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return _buildMessageBubble(_messages[index], cs);
      },
    );
  }

  Widget _buildMessageBubble(Message msg, ColorScheme cs) {
    // 系统通知（加好友 / 群组变更 / 撤回 / OA 等）—— 居中灰文，不画头像气泡
    if (isSystemNotification(msg.contentType)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            systemMessageDisplay(msg),
            style: TextStyle(
              color: cs.outline,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final isMe = msg.sendID == IMService.instance.currentUserId;
    final time = _formatMsgTime(msg.sendTime);
    final senderName = msg.senderNickname ?? '';

    return GestureDetector(
      onLongPress: () => _showMessageActions(msg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe) _buildAvatar(msg, cs),
            if (!isMe) const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isMe && widget.conversationType == 3)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2, left: 4),
                      child: Text(
                        senderName,
                        style: TextStyle(fontSize: 11, color: cs.outline),
                      ),
                    ),
                  Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.7,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isMe ? cs.primary : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isMe ? 16 : 4),
                        bottomRight: Radius.circular(isMe ? 4 : 16),
                      ),
                    ),
                    child: _buildContentWidget(msg, isMe, cs),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(time, style: TextStyle(fontSize: 10, color: cs.outline)),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          _buildReadStatus(msg, cs),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (isMe) const SizedBox(width: 8),
            if (isMe) _buildAvatar(msg, cs),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(Message msg, ColorScheme cs) {
    // 取头像优先级：本地 Supabase 缓存 > OpenIM 自带 senderFaceUrl（基本是空）> null
    // 不在缓存表里：可能 _ensureAvatars 还没回，显示首字母兜底，回来后 setState 会重绘
    final senderId = msg.sendID ?? '';
    final cached = senderId.isNotEmpty && _avatarCache.containsKey(senderId)
        ? _avatarCache[senderId]
        : null;
    final faceUrl = (cached != null && cached.isNotEmpty) ? cached : msg.senderFaceUrl;
    final name = msg.senderNickname ?? '?';
    return CircleAvatar(
      radius: 18,
      backgroundColor: cs.primaryContainer,
      backgroundImage: faceUrl != null && faceUrl.isNotEmpty
          ? CachedNetworkImageProvider(faceUrl)
          : null,
      child: faceUrl == null || faceUrl.isEmpty
          ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(color: cs.onPrimaryContainer, fontSize: 14))
          : null,
    );
  }

  Widget _buildContentWidget(Message msg, bool isMe, ColorScheme cs) {
    final textColor = isMe ? cs.onPrimary : cs.onSurface;

    switch (msg.contentType) {
      case MessageType.text:
        return SelectableText(
          msg.textElem?.content ?? '',
          style: TextStyle(color: textColor, fontSize: 15),
        );
      case MessageType.picture:
        final url = msg.pictureElem?.bigPicture?.url ??
            msg.pictureElem?.sourcePicture?.url;
        if (url != null && url.isNotEmpty) {
          return GestureDetector(
            onTap: () => _openImageViewer(url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: url,
                cacheManager: ImMediaCacheManager.instance,
                width: 200,
                fit: BoxFit.cover,
                placeholder: (_, __) => SizedBox(
                  width: 200,
                  height: 150,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                errorWidget: (_, __, ___) => _ExpiredPlaceholder(width: 200, height: 150, cs: cs),
              ),
            ),
          );
        }
        return Text(T.of(context).imPreviewImage, style: TextStyle(color: textColor));
      case MessageType.voice:
        final duration = msg.soundElem?.duration ?? 0;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic, size: 16, color: textColor),
            const SizedBox(width: 4),
            Text('${duration}s', style: TextStyle(color: textColor)),
          ],
        );
      case MessageType.video:
        final videoUrl = msg.videoElem?.videoUrl;
        final snapUrl = msg.videoElem?.snapshotUrl;
        final duration = msg.videoElem?.duration ?? 0;
        // 缩略图 + 中间播放图标 + 右下时长。点击 → 全屏播放
        return GestureDetector(
          onTap: videoUrl != null && videoUrl.isNotEmpty
              ? () => _openVideoPlayer(videoUrl)
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (snapUrl != null && snapUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: snapUrl,
                    cacheManager: ImMediaCacheManager.instance,
                    width: 200,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => _ExpiredPlaceholder(width: 200, height: 150, cs: cs),
                  )
                else
                  Container(
                    width: 200,
                    height: 150,
                    color: cs.surfaceContainerHighest,
                  ),
                const Icon(
                  Icons.play_circle_filled,
                  size: 48,
                  color: Colors.white70,
                ),
                if (duration > 0)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _fmtDuration(duration),
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      case MessageType.file:
        final fileName = msg.fileElem?.fileName ?? T.of(context).imAttachmentFile;
        final fileSize = msg.fileElem?.fileSize ?? 0;
        final url = msg.fileElem?.sourceUrl ?? '';
        return GestureDetector(
          onTap: url.isNotEmpty
              ? () => _openFileMessage(url: url, fileName: fileName)
              : null,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insert_drive_file, size: 32, color: textColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fileName,
                        style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _fmtFileSize(fileSize),
                        style: TextStyle(color: textColor.withValues(alpha: 0.7), fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      default:
        // 其余罕见类型（card / merger / location / customFace / quote / advancedText / custom 等）
        // 走 message_preview 的标准映射，至少给个有意义的中文 placeholder。
        // 系统通知在 _buildMessageBubble 顶部已经被拦截，这里走不到。
        return Text(previewMessage(msg), style: TextStyle(color: textColor));
    }
  }

  Widget _buildReadStatus(Message msg, ColorScheme cs) {
    // 状态优先级：sending（转圈）→ sendFailed（红感叹）→ isRead（双勾）→ 默认（单勾）
    final status = msg.status;
    if (status == MessageStatus.sending) {
      return SizedBox(
        width: 12, height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.outline),
      );
    }
    if (status == MessageStatus.failed) {
      return Icon(Icons.error_outline, size: 14, color: cs.error);
    }
    final isRead = msg.isRead ?? false;
    return Icon(
      isRead ? Icons.done_all : Icons.done,
      size: 14,
      color: isRead ? cs.primary : cs.outline,
    );
  }

  String _formatMsgTime(int? timestamp) {
    if (timestamp == null || timestamp == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildInputBar(ColorScheme cs) {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant.withAlpha(80))),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: cs.primary),
            onPressed: _showAttachmentOptions,
          ),
          Expanded(
            child: TextField(
              controller: _inputController,
              focusNode: _focusNode,
              textInputAction: TextInputAction.send,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: T.of(context).imChatInputHint,
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _sendText(),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(Icons.send, color: cs.primary),
            onPressed: _sendText,
          ),
        ],
      ),
    );
  }

  void _showMessageActions(Message msg) {
    final isMe = msg.sendID == IMService.instance.currentUserId;
    final cs = Theme.of(context).colorScheme;
    final s = T.of(context);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.contentType == MessageType.text)
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(s.imActionCopy),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.textElem?.content ?? ''));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(s.imToastCopied), duration: const Duration(seconds: 1)),
                  );
                },
              ),
            if (isMe)
              ListTile(
                leading: Icon(Icons.undo, color: cs.error),
                title: Text(s.imActionRevoke),
                onTap: () async {
                  Navigator.pop(ctx);
                  final now = DateTime.now().millisecondsSinceEpoch;
                  final sendTime = msg.sendTime ?? 0;
                  if (now - sendTime > 2 * 60 * 1000) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(s.imToastRevokeExpired)),
                    );
                    return;
                  }
                  final ok = await IMService.instance.revokeMessage(
                    conversationID: widget.conversationID,
                    message: msg,
                  );
                  if (ok && mounted) {
                    setState(() {
                      _messages.removeWhere((m) => m.clientMsgID == msg.clientMsgID);
                    });
                  }
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: cs.error),
              title: Text(s.delete),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await OpenIM.iMManager.messageManager.deleteMessageFromLocalAndSvr(
                    conversationID: widget.conversationID,
                    clientMsgID: msg.clientMsgID!,
                  );
                  if (mounted) {
                    setState(() {
                      _messages.removeWhere((m) => m.clientMsgID == msg.clientMsgID);
                    });
                  }
                } catch (e) {
                  debugPrint('[IM] 删除消息失败: $e');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 图片：picker → 高清/普通选择 → 上传 → sendImageByUrl ----------

  /// 从相册或相机选一张图，让用户选高清/普通画质，上传到 MinIO，发送系统图片消息。
  ///
  /// 进度处理：
  ///   - 选完图立刻插一条带 [Sending...] 文案的占位 (status=sending)，clientMsgID 暂存
  ///   - 上传过程中 setState 把同一占位的进度文字刷成"上传中 30%..."
  ///   - 上传完拿到 URL，create + send 到 SDK，回填真实 Message 替换占位
  ///   - 上传失败 / send 失败 → 占位 status 改 failed，让用户看到能重试（重试逻辑后续做）
  Future<void> _pickAndSendImage({required bool fromCamera}) async {
    final picker = ImagePicker();
    final XFile? xfile = await picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      // imageQuality 留 null —— 后面让用户选高清/普通自己控制
    );
    if (xfile == null || !mounted) return;

    final file = File(xfile.path);
    if (!await file.exists()) return;

    // 询问高清 / 普通
    final hd = await _askHdOrCompressed();
    if (hd == null) return; // 用户取消
    if (!mounted) return;

    File toUpload = file;
    int width = 0;
    int height = 0;
    if (!hd) {
      // 普通：长边 1920、JPEG q=80。对绝大多数手机原图（5~10MB）能压到 ~500KB
      final compressed = await _compressImage(file);
      if (compressed != null) toUpload = compressed;
    }
    // 读出真实尺寸（OpenIM picture 消息要 w/h，对端列表才能算 aspect ratio）
    final dim = await _readImageDim(toUpload);
    width = dim?.$1 ?? 0;
    height = dim?.$2 ?? 0;
    final size = await toUpload.length();

    // 占位消息（先不真实 createMessage，临时用一个本地 textMessage 假装；
    // 等上传完拿到 URL 再替换成真正的 picture 消息）
    final placeholder = await IMService.instance.createTextMessage('[图片上传中...]');
    if (!mounted) return;
    setState(() => _messages.insert(0, placeholder));

    final upload = await ImMediaUploader.uploadFileFull(
      toUpload,
      purpose: ImMediaPurpose.image,
      onProgress: (sent, total) {
        if (!mounted) return;
        // 写到占位消息上，每帧不强制刷新（避免抖动）
        final pct = total > 0 ? (sent * 100 ~/ total) : 0;
        placeholder.textElem?.content = '[图片上传中 $pct%]';
        // 触发轻量 rebuild
        if (sent == total || pct % 10 == 0) setState(() {});
      },
    );

    if (upload == null) {
      _markPlaceholderFailed(placeholder, '[图片上传失败]');
      return;
    }

    // 真正发送 picture 消息。sourcePath 必传 —— SDK native 端要本地文件
    // 计算 MD5 当 message UUID。本地文件可以是压缩后的临时文件，发完即删（OS
    // 会清 tmpDir）；OpenIM 不会再重新上传到自己的 MinIO，因为我们已经有 url。
    final sent = await IMService.instance.sendImageByUrl(
      url: upload.publicUrl,
      sourcePath: toUpload.absolute.path,
      uuid: upload.key, // MinIO key 全局唯一，正好做 PictureInfo.uuid
      width: width,
      height: height,
      size: size,
      userID: widget.userID,
      groupID: widget.groupID,
    );

    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m.clientMsgID == placeholder.clientMsgID);
      if (idx < 0) return;
      if (sent != null) {
        _messages[idx] = sent;
      } else {
        // sendImageByUrl 失败 —— 把占位标记 failed
        placeholder.status = MessageStatus.failed;
        placeholder.textElem?.content = '[图片发送失败]';
        _messages[idx] = placeholder;
      }
    });
  }

  /// 弹一个简单的 bottom-sheet 让用户选高清 / 普通。返 null 表示取消。
  Future<bool?> _askHdOrCompressed() {
    return showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_size_select_actual),
              title: Text(T.of(ctx).imImageQualityNormal),
              subtitle: Text(T.of(ctx).imImageQualityNormalSubtitle),
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality),
              title: Text(T.of(ctx).imImageQualityHd),
              subtitle: Text(T.of(ctx).imImageQualityHdSubtitle),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
  }

  /// 用 flutter_image_compress 压到长边 1920 / JPEG q=80。失败返 null（fallback 原图）
  Future<File?> _compressImage(File src) async {
    try {
      final tmpDir = await getTemporaryDirectory();
      final out = '${tmpDir.path}/im_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        src.absolute.path, out,
        minWidth: 1920, minHeight: 1920, // 长边 1920，短边按比例
        quality: 80,
        format: CompressFormat.jpeg,
      );
      if (result == null) return null;
      return File(result.path);
    } catch (e) {
      debugPrint('[IM] 图片压缩失败: $e');
      return null;
    }
  }

  /// 读图片宽高。失败返 null。
  Future<(int, int)?> _readImageDim(File file) async {
    try {
      final completer = Completer<(int, int)?>();
      final image = Image.file(file);
      image.image.resolve(const ImageConfiguration()).addListener(
        ImageStreamListener(
          (info, _) => completer.complete((info.image.width, info.image.height)),
          onError: (e, _) => completer.complete(null),
        ),
      );
      return await completer.future.timeout(const Duration(seconds: 5));
    } catch (e) {
      return null;
    }
  }

  static String _fmtDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _fmtFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  void _markPlaceholderFailed(Message placeholder, String text) {
    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m.clientMsgID == placeholder.clientMsgID);
      if (idx < 0) return;
      placeholder.status = MessageStatus.failed;
      placeholder.textElem?.content = text;
      _messages[idx] = placeholder;
    });
  }

  /// 全屏图片查看器（捏合缩放 / 双击放大）。
  void _openImageViewer(String url) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ImageViewerPage(url: url),
    ));
  }

  // ---------- 视频：picker → 抽首帧 → 上传 video + snapshot → sendVideoByUrl ----------

  Future<void> _pickAndSendVideo() async {
    final picker = ImagePicker();
    final XFile? xfile = await picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3), // 兜底，避免选超长视频
    );
    if (xfile == null || !mounted) return;

    final videoFile = File(xfile.path);
    if (!await videoFile.exists()) return;

    final placeholder = await IMService.instance.createTextMessage('[视频处理中...]');
    if (!mounted) return;
    setState(() => _messages.insert(0, placeholder));

    // 1. 抽首帧 + 探测时长 + 探测分辨率
    final tmpDir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final snapshotPath = '${tmpDir.path}/im_video_thumb_$ts.jpg';

    int width = 0, height = 0, durationSec = 0;
    try {
      final ctrl = VideoPlayerController.file(videoFile);
      await ctrl.initialize();
      width = ctrl.value.size.width.toInt();
      height = ctrl.value.size.height.toInt();
      durationSec = ctrl.value.duration.inSeconds;
      await ctrl.dispose();
    } catch (e) {
      debugPrint('[IM] 视频元数据读取失败: $e');
      // 不致命，继续；OpenIM bubble 没有 w/h 也能播
    }

    final thumbPath = await VideoThumbnail.thumbnailFile(
      video: videoFile.absolute.path,
      thumbnailPath: snapshotPath,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 720,
      quality: 75,
    );
    if (thumbPath == null) {
      _markPlaceholderFailed(placeholder, '[视频首帧抽取失败]');
      return;
    }
    final thumbFile = File(thumbPath);

    // 2. 上传缩略图
    if (mounted) {
      placeholder.textElem?.content = '[视频上传中 0%]';
      setState(() {});
    }

    final thumbUpload = await ImMediaUploader.uploadFileFull(
      thumbFile,
      purpose: ImMediaPurpose.snapshot,
    );
    if (thumbUpload == null) {
      _markPlaceholderFailed(placeholder, '[首帧上传失败]');
      return;
    }

    // 3. 上传视频本体（带进度）
    final videoUpload = await ImMediaUploader.uploadFileFull(
      videoFile,
      purpose: ImMediaPurpose.video,
      onProgress: (sent, total) {
        if (!mounted) return;
        final pct = total > 0 ? (sent * 100 ~/ total) : 0;
        placeholder.textElem?.content = '[视频上传中 $pct%]';
        if (sent == total || pct % 5 == 0) setState(() {});
      },
    );
    if (videoUpload == null) {
      _markPlaceholderFailed(placeholder, '[视频上传失败]');
      return;
    }

    // 4. 发送
    final videoSize = await videoFile.length();
    final thumbSize = await thumbFile.length();
    final mime = (xfile.mimeType ?? 'video/mp4'); // pickVideo 一般给 mp4
    final sent = await IMService.instance.sendVideoByUrl(
      videoUrl: videoUpload.publicUrl,
      videoSourcePath: videoFile.absolute.path,
      videoUuid: videoUpload.key,
      videoType: mime,
      videoSize: videoSize,
      duration: durationSec,
      snapshotUrl: thumbUpload.publicUrl,
      snapshotSourcePath: thumbFile.absolute.path,
      snapshotUuid: thumbUpload.key,
      snapshotSize: thumbSize,
      snapshotWidth: width,
      snapshotHeight: height,
      userID: widget.userID,
      groupID: widget.groupID,
    );

    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m.clientMsgID == placeholder.clientMsgID);
      if (idx < 0) return;
      if (sent != null) {
        _messages[idx] = sent;
      } else {
        placeholder.status = MessageStatus.failed;
        placeholder.textElem?.content = '[视频发送失败]';
        _messages[idx] = placeholder;
      }
    });
  }

  /// 全屏视频播放器（chewie + video_player）
  void _openVideoPlayer(String url) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _VideoPlayerPage(url: url),
    ));
  }

  // ---------- 文件：file_picker → 上传 → sendFileByUrl ----------

  Future<void> _pickAndSendFile() async {
    // type=any，不限格式；后端按 ALLOWED_EXT 白名单兜底
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false, // 我们要的是路径，不要内存里的字节
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final path = picked.path;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists() || !mounted) return;

    final fileName = picked.name;
    final placeholder = await IMService.instance.createTextMessage('[文件 $fileName 上传中...]');
    if (!mounted) return;
    setState(() => _messages.insert(0, placeholder));

    final upload = await ImMediaUploader.uploadFileFull(
      file,
      purpose: ImMediaPurpose.file,
      onProgress: (sent, total) {
        if (!mounted) return;
        final pct = total > 0 ? (sent * 100 ~/ total) : 0;
        placeholder.textElem?.content = '[文件 $fileName 上传中 $pct%]';
        if (sent == total || pct % 10 == 0) setState(() {});
      },
    );

    if (upload == null) {
      _markPlaceholderFailed(placeholder, '[文件上传失败：$fileName]');
      return;
    }

    final size = await file.length();
    final sent = await IMService.instance.sendFileByUrl(
      url: upload.publicUrl,
      sourcePath: file.absolute.path,
      uuid: upload.key,
      fileName: fileName,
      fileSize: size,
      userID: widget.userID,
      groupID: widget.groupID,
    );

    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m.clientMsgID == placeholder.clientMsgID);
      if (idx < 0) return;
      if (sent != null) {
        _messages[idx] = sent;
      } else {
        placeholder.status = MessageStatus.failed;
        placeholder.textElem?.content = '[文件发送失败：$fileName]';
        _messages[idx] = placeholder;
      }
    });
  }

  /// 点击文件气泡：下载到 app 缓存目录后调系统默认 app 打开。
  /// 同名文件已存在就直接打开（避免每次重新下载）；只用 url 做 cache key 也够了，
  /// 因为我们的 URL 是 MinIO key 直链，永久不变。
  Future<void> _openFileMessage({required String url, required String fileName}) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      // 用 url 末段做 cache key + 保留原文件名，让系统能按后缀挑 app
      final urlSeg = p.basename(Uri.parse(url).path);
      final cachedDir = Directory('${cacheDir.path}/im_files/$urlSeg');
      if (!await cachedDir.exists()) {
        await cachedDir.create(recursive: true);
      }
      final localPath = '${cachedDir.path}/$fileName';
      final f = File(localPath);

      if (!await f.exists()) {
        if (!mounted) return;
        // 简单进度：snackbar
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(content: Text(T.of(context).imDownloadingMsg), duration: const Duration(seconds: 30)),
        );
        final resp = await http.get(Uri.parse(url));
        messenger.hideCurrentSnackBar();
        if (resp.statusCode != 200) {
          if (!mounted) return;
          messenger.showSnackBar(
            SnackBar(content: Text(T.fmt(T.of(context).imDownloadFailedWith, {'code': resp.statusCode}))),
          );
          return;
        }
        await f.writeAsBytes(resp.bodyBytes);
      }

      final r = await OpenFilex.open(localPath);
      if (r.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(T.fmt(T.of(context).imOpenFailedWith, {'msg': r.message ?? ''}))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(T.fmt(T.of(context).imOpenExceptionWith, {'err': e}))),
        );
      }
    }
  }

  void _showAttachmentOptions() {
    final s = T.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildAttachmentButton(
                icon: Icons.photo,
                label: s.imAttachImage,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndSendImage(fromCamera: false);
                },
              ),
              _buildAttachmentButton(
                icon: Icons.camera_alt,
                label: s.imAttachCamera,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndSendImage(fromCamera: true);
                },
              ),
              _buildAttachmentButton(
                icon: Icons.videocam,
                label: s.imAttachVideo,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndSendVideo();
                },
              ),
              _buildAttachmentButton(
                icon: Icons.insert_drive_file,
                label: s.imAttachFile,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndSendFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: cs.onPrimaryContainer, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ],
      ),
    );
  }

  void _showGroupInfo() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupManagementPage(
          groupID: widget.conversationID,
          groupName: widget.conversationName,
        ),
      ),
    );
  }
}

/// 缩略图加载失败时的"图片已过期"占位（消息气泡里的尺寸）。
/// 触发：MinIO `im-media` 7 天 lifecycle 已删 + 本地缓存里也没有（比如换了设备 / 清缓存）
class _ExpiredPlaceholder extends StatelessWidget {
  final double width;
  final double height;
  final ColorScheme cs;
  const _ExpiredPlaceholder({required this.width, required this.height, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history_toggle_off, color: cs.outline, size: 32),
          const SizedBox(height: 6),
          Text(
            T.of(context).imImageExpired,
            style: TextStyle(color: cs.outline, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 全屏视频播放页：chewie + video_player。autoplay。
class _VideoPlayerPage extends StatefulWidget {
  final String url;
  const _VideoPlayerPage({required this.url});

  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
  VideoPlayerController? _vpc;
  ChewieController? _cc;
  String? _err;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      _vpc = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await _vpc!.initialize();
      _cc = ChewieController(
        videoPlayerController: _vpc!,
        autoPlay: true,
        looping: false,
        allowFullScreen: false, // 已经全屏了
        showControlsOnInitialize: true,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  @override
  void dispose() {
    _cc?.dispose();
    _vpc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_err != null) {
      body = Center(
        child: Text(T.fmt(T.of(context).imVideoLoadFailedWith, {'err': _err}),
            style: const TextStyle(color: Colors.white)),
      );
    } else if (_cc == null) {
      body = const Center(child: CircularProgressIndicator(color: Colors.white));
    } else {
      body = Center(child: Chewie(controller: _cc!));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// 全屏图片预览页：黑底 + photo_view 捏合缩放 + 双击放大。
/// 顶部 close（左上）+ download（右上）覆盖在图上。
class _ImageViewerPage extends StatefulWidget {
  final String url;
  const _ImageViewerPage({required this.url});

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  bool _saving = false;

  Future<void> _saveToAlbum() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final s = T.of(context);
    try {
      // gal 在 iOS 第一次会弹相册写入权限；在 Android 13+ 不要权限
      final granted = await Gal.hasAccess(toAlbum: true) || await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        messenger.showSnackBar(SnackBar(content: Text(s.imSaveFailed)));
        return;
      }
      // 从 cache_manager 拿本地文件（如果已经缓存过）；没缓存就 http 下一次
      final fileInfo = await ImMediaCacheManager.instance.getFileFromCache(widget.url);
      String localPath;
      if (fileInfo != null) {
        localPath = fileInfo.file.path;
      } else {
        final downloaded = await ImMediaCacheManager.instance.downloadFile(widget.url);
        localPath = downloaded.file.path;
      }
      await Gal.putImage(localPath);
      messenger.showSnackBar(SnackBar(content: Text(s.imSaveSuccess)));
    } catch (e) {
      debugPrint('[IM] 保存到相册失败: $e');
      messenger.showSnackBar(SnackBar(content: Text(s.imSaveFailed)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: PhotoView(
              imageProvider: CachedNetworkImageProvider(
                widget.url,
                cacheManager: ImMediaCacheManager.instance,
              ),
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4,
              loadingBuilder: (_, __) => const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
              errorBuilder: (_, __, ___) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.history_toggle_off, color: Colors.white54, size: 48),
                    const SizedBox(height: 8),
                    Text(
                      T.of(context).imImageExpired,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.download_rounded, color: Colors.white),
              tooltip: T.of(context).imSaveToAlbum,
              onPressed: _saving ? null : _saveToAlbum,
            ),
          ),
        ],
      ),
    );
  }
}
