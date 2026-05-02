// 联系人 / 好友页
// ─────────────────────────────────────────────────────────
// 功能：
//   1. 列表：当前所有好友，点击进入 1:1 聊天
//   2. "新的朋友" 入口：未处理的好友申请数量徽章 + 进入处理页
//   3. 右上 + 按钮：输入 user_id 发好友申请
//
// OpenIM 加好友默认走"申请—同意"流：
//   A 调 addFriend(B) → B 在 getFriendApplicationListAsRecipient 看到 → B 同意 → 双向加好友
//
// user_id 来自业务系统的 Supabase user.id（UUID 字符串）。本期没好友搜索，
// 必须明文输入对方 user_id（"加好友"页头部显示自己的 user_id 方便对方加）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'im_service.dart';
import 'chat_page.dart';
import 'create_group_page.dart';
import 'add_friend_search_page.dart';

class IMFriendPage extends StatefulWidget {
  const IMFriendPage({super.key});

  @override
  State<IMFriendPage> createState() => _IMFriendPageState();
}

class _IMFriendPageState extends State<IMFriendPage> {
  List<FriendInfo> _friends = [];
  int _pendingApplications = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _setupListener();
  }

  void _setupListener() {
    IMService.instance.setFriendshipListener(OnFriendshipListener(
      onFriendApplicationAdded: (_) => _load(),
      onFriendApplicationAccepted: (_) => _load(),
      onFriendApplicationRejected: (_) => _load(),
      onFriendAdded: (_) => _load(),
      onFriendDeleted: (_) => _load(),
      onFriendInfoChanged: (_) => _load(),
    ));
  }

  Future<void> _load() async {
    final friends = await IMService.instance.getFriendList();
    final apps = await IMService.instance.getIncomingFriendApplications();
    final pending = apps.where((a) => (a.handleResult ?? 0) == 0).length;
    if (!mounted) return;
    setState(() {
      _friends = friends;
      _pendingApplications = pending;
      _loading = false;
    });
  }

  String _myUserId() => IMService.instance.currentUserId ?? '?';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('通讯录'),
        centerTitle: true,
        actions: [
          // 一个 + 按钮，点开二选一菜单：加好友 / 建群
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: '添加',
            onSelected: (v) {
              if (v == 'add_friend') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddFriendSearchPage()),
                ).then((_) => _load());
              } else if (v == 'create_group') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CreateGroupPage()),
                ).then((_) => _load());
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'add_friend',
                child: ListTile(
                  leading: Icon(Icons.person_add_alt_1),
                  title: Text('加好友'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'create_group',
                child: ListTile(
                  leading: Icon(Icons.group_add),
                  title: Text('建群'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          // 顶部：我的 user_id —— 复制给对方加
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withAlpha(120),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.fingerprint, color: cs.primary),
                const SizedBox(width: 8),
                const Text('我的 ID:', style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    _myUserId(),
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: cs.onSurface),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _myUserId()));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制 ID'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
              ],
            ),
          ),

          // 新的朋友入口
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.tertiaryContainer,
              child: Icon(Icons.person_add, color: cs.onTertiaryContainer),
            ),
            title: const Text('新的朋友'),
            trailing: _pendingApplications > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$_pendingApplications',
                      style: TextStyle(color: cs.onError, fontSize: 12),
                    ),
                  )
                : const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _FriendApplicationPage()),
              );
              _load();
            },
          ),

          const Divider(height: 1),

          // 好友列表
          if (_friends.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60),
              child: Column(
                children: [
                  Icon(Icons.people_outline, size: 56, color: cs.outline),
                  const SizedBox(height: 12),
                  Text('还没有好友', style: TextStyle(color: cs.outline, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('点右上角 + 加好友', style: TextStyle(color: cs.outline, fontSize: 13)),
                ],
              ),
            )
          else
            ..._friends.map((f) => _buildFriendTile(f, cs)),
        ],
      ),
    );
  }

  Widget _buildFriendTile(FriendInfo f, ColorScheme cs) {
    final name = (f.remark?.isNotEmpty == true ? f.remark : null) ??
        (f.nickname?.isNotEmpty == true ? f.nickname : null) ??
        f.userID ??
        '?';
    final faceUrl = f.faceURL;

    return Dismissible(
      key: Key('friend-${f.userID}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除好友'),
            content: Text('确定删除 $name？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(backgroundColor: cs.error),
                child: const Text('删除'),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) async {
        await IMService.instance.deleteFriend(f.userID!);
        _load();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: cs.error,
        child: Icon(Icons.delete, color: cs.onError),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: cs.primaryContainer,
          backgroundImage: faceUrl != null && faceUrl.isNotEmpty ? NetworkImage(faceUrl) : null,
          child: faceUrl == null || faceUrl.isEmpty
              ? Text(name[0].toUpperCase(),
                  style: TextStyle(color: cs.onPrimaryContainer))
              : null,
        ),
        title: Text(name),
        subtitle: Text(
          f.userID ?? '',
          style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: cs.outline),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          // 进 1:1 聊天页。conversationID 用 OpenIM 标准格式 si_<a>_<b>（按 ID 字典序拼）
          final myId = IMService.instance.currentUserId ?? '';
          final ids = [myId, f.userID!]..sort();
          final convId = 'si_${ids[0]}_${ids[1]}';
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => IMChatPage(
                conversationID: convId,
                conversationName: name,
                faceURL: faceUrl,
                conversationType: 1, // 1=单聊
                userID: f.userID,
                groupID: null,
              ),
            ),
          );
        },
      ),
    );
  }

}

// ============================================================
// 好友申请处理页
// ============================================================

class _FriendApplicationPage extends StatefulWidget {
  const _FriendApplicationPage();

  @override
  State<_FriendApplicationPage> createState() => _FriendApplicationPageState();
}

class _FriendApplicationPageState extends State<_FriendApplicationPage> {
  List<FriendApplicationInfo> _apps = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apps = await IMService.instance.getIncomingFriendApplications();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  String _statusText(int? r) {
    switch (r) {
      case 1:
        return '已同意';
      case -1:
        return '已拒绝';
      default:
        return '待处理';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('新的朋友')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _apps.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox_outlined, size: 56, color: cs.outline),
                      const SizedBox(height: 12),
                      Text('还没有人申请加你', style: TextStyle(color: cs.outline)),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _apps.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final a = _apps[i];
                    final pending = (a.handleResult ?? 0) == 0;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.primaryContainer,
                        backgroundImage: (a.fromFaceURL?.isNotEmpty ?? false)
                            ? NetworkImage(a.fromFaceURL!)
                            : null,
                        child: (a.fromFaceURL?.isEmpty ?? true)
                            ? Text(((a.fromNickname ?? a.fromUserID ?? '?')[0])
                                .toUpperCase())
                            : null,
                      ),
                      title: Text(a.fromNickname?.isNotEmpty == true
                          ? a.fromNickname!
                          : (a.fromUserID ?? '?')),
                      subtitle: Text(
                        (a.reqMsg?.isNotEmpty == true)
                            ? a.reqMsg!
                            : '请求加你为好友',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: pending
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.close, color: cs.error),
                                  tooltip: '拒绝',
                                  onPressed: () async {
                                    await IMService.instance.rejectFriendApplication(
                                      fromUserID: a.fromUserID!,
                                    );
                                    _load();
                                  },
                                ),
                                IconButton(
                                  icon: Icon(Icons.check, color: Colors.green),
                                  tooltip: '同意',
                                  onPressed: () async {
                                    await IMService.instance.acceptFriendApplication(
                                      fromUserID: a.fromUserID!,
                                    );
                                    _load();
                                  },
                                ),
                              ],
                            )
                          : Text(
                              _statusText(a.handleResult),
                              style: TextStyle(color: cs.outline, fontSize: 13),
                            ),
                    );
                  },
                ),
    );
  }
}
