import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'im_models.dart';

/// 群组管理页面 — 群详情、成员管理、群设置
class GroupManagementPage extends StatefulWidget {
  final String groupID;
  final String groupName;

  const GroupManagementPage({
    super.key,
    required this.groupID,
    required this.groupName,
  });

  @override
  State<GroupManagementPage> createState() => _GroupManagementPageState();
}

class _GroupManagementPageState extends State<GroupManagementPage> {
  GroupInfo? _groupInfo;
  List<GroupMemberSummary> _members = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadGroupInfo();
  }

  Future<void> _loadGroupInfo() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final groups = await OpenIM.iMManager.groupManager.getGroupsInfo(
        groupIDList: [widget.groupID],
      );
      if (groups.isNotEmpty) {
        _groupInfo = groups.first;
      }

      final membersList = await OpenIM.iMManager.groupManager.getGroupMemberList(
        groupID: widget.groupID,
      );
      _members = membersList
          .map((m) => GroupMemberSummary.fromGroupMembersInfo(m))
          .toList();

      if (mounted) {
        setState(() => _loading = false);
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊设置'),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: cs.error),
                      const SizedBox(height: 16),
                      Text(_error!, style: TextStyle(color: cs.outline)),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _loadGroupInfo, child: const Text('重试')),
                    ],
                  ),
                )
              : _buildContent(cs),
    );
  }

  Widget _buildContent(ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 群头像和名称
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: cs.primaryContainer,
                backgroundImage: _groupInfo?.faceURL != null && _groupInfo!.faceURL!.isNotEmpty
                    ? NetworkImage(_groupInfo!.faceURL!)
                    : null,
                child: _groupInfo?.faceURL == null || _groupInfo!.faceURL!.isEmpty
                    ? Icon(Icons.group, size: 40, color: cs.onPrimaryContainer)
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                _groupInfo?.groupName ?? widget.groupName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '${_members.length} 名成员',
                style: TextStyle(color: cs.outline),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 群公告
        if (_groupInfo?.notification != null && _groupInfo!.notification!.isNotEmpty) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.campaign, size: 18, color: cs.primary),
                      const SizedBox(width: 8),
                      Text('群公告', style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_groupInfo!.notification!, style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // 成员列表
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.people, color: cs.primary),
                title: const Text('群成员'),
                trailing: Text('${_members.length}', style: TextStyle(color: cs.outline)),
              ),
              const Divider(height: 1),
              ..._members.map((member) => ListTile(
                leading: CircleAvatar(
                  radius: 18,
                  backgroundColor: cs.secondaryContainer,
                  backgroundImage: member.faceURL != null && member.faceURL!.isNotEmpty
                      ? NetworkImage(member.faceURL!)
                      : null,
                  child: member.faceURL == null || member.faceURL!.isEmpty
                      ? Text(
                          member.nickname.isNotEmpty ? member.nickname[0].toUpperCase() : '?',
                          style: TextStyle(color: cs.onSecondaryContainer, fontSize: 14),
                        )
                      : null,
                ),
                title: Row(
                  children: [
                    Text(member.nickname),
                    if (member.role == 3) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: cs.tertiaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('群主', style: TextStyle(fontSize: 10, color: cs.onTertiaryContainer)),
                      ),
                    ] else if (member.role == 2) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('管理员', style: TextStyle(fontSize: 10, color: cs.onSecondaryContainer)),
                      ),
                    ],
                  ],
                ),
              )),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 邀请成员
        OutlinedButton.icon(
          onPressed: _showInviteDialog,
          icon: const Icon(Icons.person_add),
          label: const Text('邀请成员'),
        ),
        const SizedBox(height: 8),

        // 退出群聊
        FilledButton.icon(
          onPressed: _confirmQuitGroup,
          icon: const Icon(Icons.exit_to_app),
          label: const Text('退出群聊'),
          style: FilledButton.styleFrom(
            backgroundColor: cs.error,
            foregroundColor: cs.onError,
          ),
        ),
      ],
    );
  }

  void _showInviteDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('邀请成员'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: '用户 ID',
            hintText: '输入要邀请的用户 ID',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final uid = controller.text.trim();
              if (uid.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await OpenIM.iMManager.groupManager.inviteUserToGroup(
                  groupID: widget.groupID,
                  userIDList: [uid],
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('邀请已发送')),
                  );
                  _loadGroupInfo();
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('邀请失败: $e')),
                  );
                }
              }
            },
            child: const Text('邀请'),
          ),
        ],
      ),
    );
  }

  void _confirmQuitGroup() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出群聊'),
        content: Text('确定退出「${_groupInfo?.groupName ?? widget.groupName}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await OpenIM.iMManager.groupManager.quitGroup(groupID: widget.groupID);
                if (mounted) {
                  Navigator.pop(context);
                  Navigator.pop(context);
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('退出失败: $e')),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('确定退出'),
          ),
        ],
      ),
    );
  }
}
