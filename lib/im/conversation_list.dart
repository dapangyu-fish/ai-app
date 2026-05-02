import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'im_service.dart';
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

  @override
  void initState() {
    super.initState();
    _loadConversations();
    _setupConversationListener();
  }

  void _setupConversationListener() {
    OpenIM.iMManager.conversationManager.setConversationListener(
      OnConversationListener(
        onConversationChanged: (list) {
          _loadConversations();
        },
        onNewConversation: (list) {
          _loadConversations();
        },
        onTotalUnreadMessageCountChanged: (count) {
          if (mounted) setState(() {});
        },
      ),
    );
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

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }

  String _getLastMessageContent(ConversationInfo conv) =>
      previewMessage(conv.latestMsg);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.contacts_outlined),
            tooltip: '联系人',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const IMFriendPage()),
              ).then((_) => _loadConversations());
            },
          ),
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: '创建群聊',
            onPressed: _showCreateGroupDialog,
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
              child: const Text('重试'),
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
            Text('暂无消息', style: TextStyle(color: cs.outline, fontSize: 16)),
            const SizedBox(height: 8),
            Text('开始一段对话吧', style: TextStyle(color: cs.outline, fontSize: 13)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadConversations,
      child: ListView.separated(
        itemCount: _conversations.length,
        separatorBuilder: (_, __) => Divider(height: 1, indent: 72, color: cs.outlineVariant.withAlpha(80)),
        itemBuilder: (context, index) {
          final conv = _conversations[index];
          return _buildConversationTile(conv, cs);
        },
      ),
    );
  }

  Widget _buildConversationTile(ConversationInfo conv, ColorScheme cs) {
    final name = conv.showName ?? '未知';
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
            title: const Text('确认删除'),
            content: Text('删除与 $name 的会话？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
            ],
          ),
        );
      },
      onDismissed: (_) async {
        try {
          await OpenIM.iMManager.conversationManager
              .deleteConversationAndDeleteAllMsg(conversationID: conv.conversationID);
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
              ? NetworkImage(faceUrl)
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
            Text(
              time,
              style: TextStyle(fontSize: 12, color: cs.outline),
            ),
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
          Navigator.of(context).push(
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
          ).then((_) => _loadConversations());
        },
        onLongPress: () => _showConversationActions(conv),
      ),
    );
  }

  void _showConversationActions(ConversationInfo conv) {
    final isPinned = conv.isPinned ?? false;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(isPinned ? '取消置顶' : '置顶'),
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
              leading: Icon(Icons.mark_chat_read, color: Theme.of(context).colorScheme.primary),
              title: const Text('标记已读'),
              onTap: () async {
                Navigator.pop(ctx);
                await IMService.instance.markConversationRead(
                  conversationID: conv.conversationID,
                );
                _loadConversations();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: const Text('删除会话'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await OpenIM.iMManager.conversationManager
                      .deleteConversationAndDeleteAllMsg(conversationID: conv.conversationID);
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

  void _showCreateGroupDialog() {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建群聊'),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: '群名称',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              final group = await IMService.instance.createGroup(
                groupName: name,
                memberUserIDs: [],
              );
              if (group != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('群聊 "$name" 创建成功')),
                );
                _loadConversations();
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }
}
