// 加好友 - 搜索页
// ─────────────────────────────────────────────────────────
// 之前的实现是 AlertDialog + 必须手输完整 user_id（UUID）。这个页面替代它：
//   - 单输入框，支持 email / username / uuid（带或不带 hyphen）三种
//   - 输入 ≥ 2 字符自动模糊搜索（debounce 350ms）
//   - 结果列表，点击 → 弹附言 → 发送好友申请

import 'dart:async';

import 'package:flutter/material.dart';
import 'im_service.dart';

class AddFriendSearchPage extends StatefulWidget {
  const AddFriendSearchPage({super.key});

  @override
  State<AddFriendSearchPage> createState() => _AddFriendSearchPageState();
}

class _AddFriendSearchPageState extends State<AddFriendSearchPage> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  String _lastQuery = '';
  bool _emptyAfterSearch = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      // 清空结果，不发请求
      setState(() {
        _results = [];
        _emptyAfterSearch = false;
        _searching = false;
        _lastQuery = q;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _doSearch(q));
  }

  Future<void> _doSearch(String q) async {
    setState(() {
      _searching = true;
      _lastQuery = q;
    });
    final users = await IMService.instance.searchUsers(q);
    if (!mounted || _searchCtrl.text != q) return; // 输入已变，丢弃这次结果
    setState(() {
      _searching = false;
      _results = users;
      _emptyAfterSearch = users.isEmpty;
    });
  }

  String get _myUserId => IMService.instance.currentUserId ?? '';

  Future<void> _onTapUser(Map<String, dynamic> user) async {
    final imUserId = user['im_user_id'] as String? ?? '';
    if (imUserId.isEmpty || imUserId == _myUserId) return;

    final reasonCtrl = TextEditingController(text: '我想加你为好友');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('发送好友申请'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 选中用户卡片
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withAlpha(120),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: cs.primary,
                      backgroundImage: (user['face_url'] as String?)?.isNotEmpty == true
                          ? NetworkImage(user['face_url'])
                          : null,
                      child: (user['face_url'] as String? ?? '').isEmpty
                          ? Text(
                              ((user['nickname'] as String? ?? '?')[0]).toUpperCase(),
                              style: TextStyle(color: cs.onPrimary),
                            )
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user['nickname'] as String? ?? '',
                              style: const TextStyle(fontWeight: FontWeight.w500)),
                          Text(user['email'] as String? ?? '',
                              style: TextStyle(color: cs.outline, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                decoration: InputDecoration(
                  labelText: '附言',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('发送申请'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    final ok = await IMService.instance.sendFriendApplication(
      userID: imUserId,
      reqMsg: reasonCtrl.text.trim(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '申请已发送，等对方同意' : '申请发送失败'),
        backgroundColor: ok ? null : Theme.of(context).colorScheme.error,
      ),
    );
    if (ok) Navigator.of(context).pop(); // 申请发出后回退到通讯录页
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('加好友'),
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '邮箱 / 用户名 / ID 都可以搜',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchCtrl.clear();
                          _onChanged('');
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true,
              ),
              onChanged: _onChanged,
              onSubmitted: (q) => _doSearch(q),
            ),
          ),

          // 结果区
          Expanded(child: _buildResults(cs)),
        ],
      ),
    );
  }

  Widget _buildResults(ColorScheme cs) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }

    final q = _searchCtrl.text.trim();
    if (q.length < 2) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 56, color: cs.outline),
              const SizedBox(height: 12),
              Text('输入邮箱、用户名或 ID 搜索',
                  style: TextStyle(color: cs.outline)),
              const SizedBox(height: 4),
              Text('至少输入 2 个字符',
                  style: TextStyle(color: cs.outline, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    if (_emptyAfterSearch) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search, size: 56, color: cs.outline),
            const SizedBox(height: 12),
            Text('没找到匹配 "$_lastQuery" 的用户',
                style: TextStyle(color: cs.outline)),
            const SizedBox(height: 4),
            Text('对方需要先在 app 里注册',
                style: TextStyle(color: cs.outline, fontSize: 12)),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => Divider(height: 1, indent: 72, color: cs.outlineVariant),
      itemBuilder: (_, i) {
        final u = _results[i];
        final faceUrl = u['face_url'] as String? ?? '';
        final nickname = u['nickname'] as String? ?? '';
        final email = u['email'] as String? ?? '';
        final isMe = u['im_user_id'] == _myUserId;

        return ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: cs.primaryContainer,
            backgroundImage: faceUrl.isNotEmpty ? NetworkImage(faceUrl) : null,
            child: faceUrl.isEmpty
                ? Text(nickname.isNotEmpty ? nickname[0].toUpperCase() : '?',
                    style: TextStyle(color: cs.onPrimaryContainer))
                : null,
          ),
          title: Text(nickname),
          subtitle: Text(email,
              style: TextStyle(color: cs.outline, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          trailing: isMe
              ? Text('（你自己）', style: TextStyle(color: cs.outline, fontSize: 12))
              : const Icon(Icons.person_add_alt_1, size: 20),
          onTap: isMe ? null : () => _onTapUser(u),
        );
      },
    );
  }
}
