import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
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

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _markRead();
    _subscribe();
    _scrollController.addListener(_onScroll);
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
                '群聊',
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
        child: Text('暂无消息', style: TextStyle(color: cs.outline)),
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
    final faceUrl = msg.senderFaceUrl;
    final name = msg.senderNickname ?? '?';
    return CircleAvatar(
      radius: 18,
      backgroundColor: cs.primaryContainer,
      backgroundImage: faceUrl != null && faceUrl.isNotEmpty
          ? NetworkImage(faceUrl)
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
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              width: 200,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return SizedBox(
                  width: 200,
                  height: 150,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              },
              errorBuilder: (_, __, ___) => Container(
                width: 200,
                height: 150,
                color: cs.surfaceContainerHighest,
                child: Icon(Icons.broken_image, color: cs.outline),
              ),
            ),
          );
        }
        return Text('[图片]', style: TextStyle(color: textColor));
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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam, size: 16, color: textColor),
            const SizedBox(width: 4),
            Text('[视频]', style: TextStyle(color: textColor)),
          ],
        );
      case MessageType.file:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, size: 16, color: textColor),
            const SizedBox(width: 4),
            Text(msg.fileElem?.fileName ?? '[文件]',
                style: TextStyle(color: textColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
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
                hintText: '输入消息...',
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

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.contentType == MessageType.text)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.textElem?.content ?? ''));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
                  );
                },
              ),
            if (isMe)
              ListTile(
                leading: Icon(Icons.undo, color: cs.error),
                title: const Text('撤回'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final now = DateTime.now().millisecondsSinceEpoch;
                  final sendTime = msg.sendTime ?? 0;
                  if (now - sendTime > 2 * 60 * 1000) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('超过 2 分钟无法撤回')),
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
              title: const Text('删除'),
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

  void _showAttachmentOptions() {
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
                label: '图片',
                onTap: () {
                  Navigator.pop(ctx);
                  // TODO: 集成 image_picker 发送图片
                },
              ),
              _buildAttachmentButton(
                icon: Icons.camera_alt,
                label: '拍照',
                onTap: () {
                  Navigator.pop(ctx);
                  // TODO: 集成 camera 拍照发送
                },
              ),
              _buildAttachmentButton(
                icon: Icons.insert_drive_file,
                label: '文件',
                onTap: () {
                  Navigator.pop(ctx);
                  // TODO: 集成 file_picker 发送文件
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
