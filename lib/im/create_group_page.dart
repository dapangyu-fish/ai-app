// 创建群聊页 —— 输入群名 + 多选好友
// ─────────────────────────────────────────────────────────
// 之前的实现是个 AlertDialog + memberUserIDs: [] 空列表 → OpenIM 创建群但无成员，
// 创建后没 conversation 可见，UI 看起来像 "没反应"。
//
// 改成：
//   1. 全屏页：顶部群名输入 + 好友列表（多选）
//   2. 已选成员数 footer，少于 1 人不允许创建
//   3. 创建成功后立刻 push 进群聊页面

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import '../i18n/framework_strings.dart';
import 'chat_page.dart';
import 'im_service_io.dart';

class CreateGroupPage extends StatefulWidget {
  /// 预选好友（从联系人页 ListTile 长按"建群"时可以预选这一个）
  final List<String> preselectedUserIDs;
  const CreateGroupPage({super.key, this.preselectedUserIDs = const []});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final _nameCtrl = TextEditingController();
  List<FriendInfo> _friends = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.preselectedUserIDs);
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final friends = await IMService.instance.getFriendList();
    if (!mounted) return;
    setState(() {
      _friends = friends;
      _loading = false;
    });
  }

  bool get _canSubmit =>
      !_creating && _nameCtrl.text.trim().isNotEmpty && _selected.isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _creating = true);

    final group = await IMService.instance.createGroup(
      groupName: _nameCtrl.text.trim(),
      memberUserIDs: _selected.toList(),
    );

    if (!mounted) return;

    if (group == null || group.groupID.isEmpty) {
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(T.of(context).imCreateGroupFailed)),
      );
      return;
    }

    // 成功：先关掉创建页，再 push 进群聊
    Navigator.of(context).pop(group);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IMChatPage(
          conversationID:
              'sg_${group.groupID}', // OpenIM 群聊 conversationID 标准格式
          conversationName: group.groupName ?? _nameCtrl.text.trim(),
          faceURL: group.faceURL,
          conversationType: 3, // 3=群聊
          userID: null,
          groupID: group.groupID,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.imCreateGroupTitle),
        actions: [
          TextButton(
            onPressed: _canSubmit ? _submit : null,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.imCreate),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 群名
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: InputDecoration(
                      labelText: s.imGroupNameLabel,
                      hintText: s.imGroupNameHint,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),

                // 已选 + 列表头
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        s.imSelectMembers,
                        style: TextStyle(color: cs.outline),
                      ),
                      const Spacer(),
                      Text(
                        T.fmt(s.imSelectedCount, {'n': _selected.length}),
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                // 好友列表
                Expanded(
                  child: _friends.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.people_outline,
                                size: 56,
                                color: cs.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                s.imEmptyFriends,
                                style: TextStyle(color: cs.outline),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                s.imEmptyFriendsForGroupHint,
                                style: TextStyle(
                                  color: cs.outline,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _friends.length,
                          itemBuilder: (_, i) {
                            final f = _friends[i];
                            final id = f.userID ?? '';
                            final checked = _selected.contains(id);
                            final name =
                                (f.remark?.isNotEmpty == true
                                    ? f.remark
                                    : null) ??
                                (f.nickname?.isNotEmpty == true
                                    ? f.nickname
                                    : null) ??
                                id;
                            final faceUrl = f.faceURL;

                            return CheckboxListTile(
                              value: checked,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                });
                              },
                              secondary: CircleAvatar(
                                radius: 20,
                                backgroundColor: cs.primaryContainer,
                                backgroundImage: (faceUrl?.isNotEmpty ?? false)
                                    ? CachedNetworkImageProvider(faceUrl!)
                                    : null,
                                child: (faceUrl?.isEmpty ?? true)
                                    ? Text(
                                        name.isNotEmpty
                                            ? name[0].toUpperCase()
                                            : '?',
                                        style: TextStyle(
                                          color: cs.onPrimaryContainer,
                                        ),
                                      )
                                    : null,
                              ),
                              title: Text(name),
                              subtitle: Text(
                                id,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: cs.outline,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
