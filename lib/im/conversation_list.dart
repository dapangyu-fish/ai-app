import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import '../i18n/framework_strings.dart';
import 'im_service_io.dart';
import 'chat_page.dart';
import 'friend_page.dart';
import 'message_preview.dart';

/// 会话列表页面 - 类似微信消息列表
class IMConversationPage extends StatefulWidget {
  const IMConversationPage({super.key});

  @override
  State<IMConversationPage> createState() => _IMConversationPageState();
}

class _IMConversationPageState extends State<IMConversationPage> {
  List<ConversationInfo> _conversations = [];
  bool _loading = true;
  String? _error;

  StreamSubscription<List<ConversationInfo>>? _convChangedSub;
  StreamSubscription<Message>? _msgSub;

  @override
  void initState() {
    super.initState();
    _loadConversations();
    // 订阅 IMService 的 stream，避免直接 setConversationListener 把 IMService 内部
    // 维护未读数 totalUnreadMessageCount 的回调覆盖（以前每次进出消息页都把全局未读
    // 数 listener 踩坏，主页 badge 就一直对不上）。
    _convChangedSub = IMService.instance.conversationsChangedStream.listen((_) {
      if (mounted) _loadConversations();
    });
    _msgSub = IMService.instance.newMessageStream.listen((_) {
      if (mounted) _loadConversations(); // latestMsg / 时间戳要变
    });
  }

  @override
  void dispose() {
    _convChangedSub?.cancel();
    _msgSub?.cancel();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    try {
      final list = await IMService.instance.getConversationList();
      if (mounted) {
        setState(() {
          _conversations = list;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  String _formatTime(int? timestamp) {
    if (timestamp == null || timestamp == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(dt);
    final s = T.current;

    if (diff.inMinutes < 1) return s.imTimeJustNow;
    if (diff.inHours < 1)
      return T.fmt(s.imTimeMinutesAgo, {'n': diff.inMinutes});
    if (diff.inDays < 1) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays == 1) return s.imTimeYesterday;
    if (diff.inDays < 7) return T.fmt(s.imTimeDaysAgo, {'n': diff.inDays});
    return '${dt.month}/${dt.day}';
  }

  String _getLastMessageContent(ConversationInfo conv) =>
      previewMessage(conv.latestMsg);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.imConversationsTitle),
        centerTitle: true,
        actions: [
          // 一个入口干到底：进通讯录后再分"加好友 / 建群"
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: s.imContacts,
            onPressed: () {
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const IMFriendPage()))
                  .then((_) => _loadConversations());
            },
          ),
        ],
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 48, color: cs.outline),
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: cs.outline)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadConversations,
              child: Text(T.of(context).retry),
            ),
          ],
        ),
      );
    }

    if (_conversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: cs.outline),
            const SizedBox(height: 16),
            Text(
              T.of(context).imEmptyMessages,
              style: TextStyle(color: cs.outline, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              T.of(context).imEmptyMessagesHint,
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadConversations,
      child: ListView.separated(
        itemCount: _conversations.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 72,
          color: cs.outlineVariant.withAlpha(80),
        ),
        itemBuilder: (context, index) {
          final conv = _conversations[index];
          return _buildConversationTile(conv, cs);
        },
      ),
    );
  }

  Widget _buildConversationTile(ConversationInfo conv, ColorScheme cs) {
    final s = T.of(context);
    final name = conv.showName ?? s.imUnknownPeer;
    final lastMsg = _getLastMessageContent(conv);
    final time = _formatTime(conv.latestMsgSendTime);
    final unread = conv.unreadCount;
    final faceUrl = conv.faceURL;
    final isPinned = conv.isPinned ?? false;

    return Dismissible(
      key: Key(conv.conversationID),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.imConfirmDeleteTitle),
            content: Text(T.fmt(s.imDeleteConversationContent, {'name': name})),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(s.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(s.delete),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) async {
        try {
          await OpenIM.iMManager.conversationManager
              .deleteConversationAndDeleteAllMsg(
                conversationID: conv.conversationID,
              );
          _loadConversations();
        } catch (e) {
          debugPrint('[IM] 删除会话失败: $e');
        }
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: cs.error,
        child: Icon(Icons.delete, color: cs.onError),
      ),
      child: ListTile(
        tileColor: isPinned ? cs.surfaceContainerHighest.withAlpha(60) : null,
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: cs.primaryContainer,
          backgroundImage: faceUrl != null && faceUrl.isNotEmpty
              ? CachedNetworkImageProvider(faceUrl)
              : null,
          child: faceUrl == null || faceUrl.isEmpty
              ? Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(color: cs.onPrimaryContainer, fontSize: 18),
                )
              : null,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(time, style: TextStyle(fontSize: 12, color: cs.outline)),
          ],
        ),
        subtitle: Row(
          children: [
            Expanded(
              child: Text(
                lastMsg,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.error,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  unread > 99 ? '99+' : unread.toString(),
                  style: TextStyle(color: cs.onError, fontSize: 11),
                ),
              ),
          ],
        ),
        onTap: () {
          Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) => IMChatPage(
                    conversationID: conv.conversationID,
                    conversationName: name,
                    faceURL: faceUrl,
                    conversationType: conv.conversationType ?? 1,
                    userID: conv.userID,
                    groupID: conv.groupID,
                  ),
                ),
              )
              .then((_) => _loadConversations());
        },
        onLongPress: () => _showConversationActions(conv),
      ),
    );
  }

  void _showConversationActions(ConversationInfo conv) {
    final isPinned = conv.isPinned ?? false;
    final s = T.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(isPinned ? s.imUnpin : s.imPin),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await OpenIM.iMManager.conversationManager.pinConversation(
                    conversationID: conv.conversationID,
                    isPinned: !isPinned,
                  );
                  _loadConversations();
                } catch (e) {
                  debugPrint('[IM] 置顶操作失败: $e');
                }
              },
            ),
            ListTile(
              leading: Icon(
                Icons.mark_chat_read,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(s.imMarkRead),
              onTap: () async {
                Navigator.pop(ctx);
                await IMService.instance.markConversationRead(
                  conversationID: conv.conversationID,
                );
                _loadConversations();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(s.imDeleteConversation),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await OpenIM.iMManager.conversationManager
                      .deleteConversationAndDeleteAllMsg(
                        conversationID: conv.conversationID,
                      );
                  _loadConversations();
                } catch (e) {
                  debugPrint('[IM] 删除会话失败: $e');
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
