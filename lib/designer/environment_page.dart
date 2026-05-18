import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../auth/local_data_wiper.dart';
import '../config/app_config.dart';
import '../config/environment.dart';
import '../config/environment_service.dart';

/// 服务环境管理页。隐藏入口（设置页标题连点 7 下）触发。
///
/// 切换环境的副作用：强制登出 + wipeAllLocalAccountData()，所以加确认框。
class EnvironmentPage extends StatefulWidget {
  const EnvironmentPage({super.key});

  @override
  State<EnvironmentPage> createState() => _EnvironmentPageState();
}

class _EnvironmentPageState extends State<EnvironmentPage> {
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    EnvironmentService.instance.addListener(_onEnvChanged);
  }

  @override
  void dispose() {
    EnvironmentService.instance.removeListener(_onEnvChanged);
    super.dispose();
  }

  void _onEnvChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmAndSwitch(Environment target) async {
    final svc = EnvironmentService.instance;
    if (target.id == svc.active.id) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换服务环境'),
        content: Text(
          '切换到「${target.name}」会：\n\n'
          '• 强制登出当前账号\n'
          '• 清空所有本地数据（聊天记录、缓存、登录态等）\n'
          '• 重新返回登录页\n\n'
          '此操作不可撤销，确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _switching = true);
    try {
      // 顺序很关键：
      // 1. 先 signOut（用老环境的 token 调老后端 /logout，告别）—— 失败吞掉
      try {
        await AuthService.signOut();
      } catch (_) {}
      // 2. wipe 本地所有数据（含 prefs.clear()）
      await wipeAllLocalAccountData();
      // 3. 激活新环境（_persistAll 会把环境列表 + active id 写回 prefs）
      await EnvironmentService.instance.activate(target.id);
      if (!mounted) return;

      // 4. 把这条路由弹掉（设置页 → 这里都 pop 掉，回到 AuthGate）
      //    AuthGate 监听 authNotifier，signOut 已经把它置 false，自动显示 AuthPage
      Navigator.of(context).popUntil((route) => route.isFirst);

      // 给一点 UI 反馈
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已切换到环境「${target.name}」，请重新登录')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切换失败：$e')),
      );
    }
  }

  Future<void> _openEdit({Environment? existing}) async {
    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EnvironmentEditPage(existing: existing),
    ));
    if (result == true && mounted) {
      setState(() {});
    }
  }

  Future<void> _confirmDelete(Environment env) async {
    if (env.id == EnvironmentService.instance.active.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('不能删除当前激活的环境，请先切换到其他环境')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除环境'),
        content: Text('确定删除「${env.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await EnvironmentService.instance.delete(env.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = EnvironmentService.instance;
    final cs = Theme.of(context).colorScheme;
    final envs = svc.all;
    final activeId = svc.active.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('服务环境'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建环境',
            onPressed: _switching ? null : () => _openEdit(),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: envs.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
            itemBuilder: (ctx, i) {
              if (i == envs.length) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  child: Text(
                    '提示：切换环境会强制登出并清空本地数据。\n'
                    '环境内某个字段留空，会回退到生产默认。',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                );
              }
              final env = envs[i];
              final isActive = env.id == activeId;
              return ListTile(
                leading: Radio<String>(
                  value: env.id,
                  groupValue: activeId,
                  onChanged: _switching ? null : (v) {
                    if (v != null) _confirmAndSwitch(env);
                  },
                ),
                title: Row(
                  children: [
                    Text(
                      env.name,
                      style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal),
                    ),
                    if (env.isBuiltin) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '默认',
                          style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  _summary(env),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                trailing: env.isBuiltin
                    ? null
                    : PopupMenuButton<String>(
                        enabled: !_switching,
                        onSelected: (v) {
                          if (v == 'edit') {
                            _openEdit(existing: env);
                          } else if (v == 'delete') {
                            _confirmDelete(env);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                onTap: _switching ? null : () => _confirmAndSwitch(env),
              );
            },
          ),
          if (_switching)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        '切换中…',
                        style: TextStyle(color: cs.surface),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _summary(Environment env) {
    if (env.isBuiltin) {
      // 直接显示当前实际生效地址
      return 'backend: ${AppConfig.backendUrl}';
    }
    final parts = <String>[];
    if (env.backendUrl != null && env.backendUrl!.isNotEmpty) {
      parts.add('backend: ${env.backendUrl}');
    }
    final overridden = [
      env.backendUrl,
      env.supabaseUrl,
      env.minioUrl,
      env.registryUrl,
      env.imApiUrl,
      env.imWsUrl,
      env.configCenterUrl,
    ].where((u) => u != null && u.isNotEmpty).length;
    if (overridden < 7) {
      parts.add('$overridden/7 自定义，其余走生产默认');
    } else {
      parts.add('全部 7 个域名已自定义');
    }
    return parts.join(' · ');
  }
}

/// 编辑/新建单个环境。null = 新建。
class EnvironmentEditPage extends StatefulWidget {
  final Environment? existing;
  const EnvironmentEditPage({super.key, this.existing});

  @override
  State<EnvironmentEditPage> createState() => _EnvironmentEditPageState();
}

class _EnvironmentEditPageState extends State<EnvironmentEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtl;
  late final TextEditingController _backendCtl;
  late final TextEditingController _supabaseCtl;
  late final TextEditingController _minioCtl;
  late final TextEditingController _registryCtl;
  late final TextEditingController _imApiCtl;
  late final TextEditingController _imWsCtl;
  late final TextEditingController _configCenterCtl;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtl = TextEditingController(text: e?.name ?? '');
    _backendCtl = TextEditingController(text: e?.backendUrl ?? '');
    _supabaseCtl = TextEditingController(text: e?.supabaseUrl ?? '');
    _minioCtl = TextEditingController(text: e?.minioUrl ?? '');
    _registryCtl = TextEditingController(text: e?.registryUrl ?? '');
    _imApiCtl = TextEditingController(text: e?.imApiUrl ?? '');
    _imWsCtl = TextEditingController(text: e?.imWsUrl ?? '');
    _configCenterCtl = TextEditingController(text: e?.configCenterUrl ?? '');
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _backendCtl.dispose();
    _supabaseCtl.dispose();
    _minioCtl.dispose();
    _registryCtl.dispose();
    _imApiCtl.dispose();
    _imWsCtl.dispose();
    _configCenterCtl.dispose();
    super.dispose();
  }

  String? _validateUrl(String? value, {required bool allowWs}) {
    if (value == null || value.trim().isEmpty) return null; // 留空合法 → 回退默认
    final v = value.trim();
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.hasAuthority) return '格式无效';
    final scheme = uri.scheme.toLowerCase();
    if (allowWs) {
      if (scheme != 'ws' && scheme != 'wss') return '协议必须是 ws:// 或 wss://';
    } else {
      if (scheme != 'http' && scheme != 'https') return '协议必须是 http:// 或 https://';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写环境名称')),
      );
      return;
    }

    String? cleanOrNull(TextEditingController c) {
      final v = c.text.trim();
      // 末尾斜杠去掉，避免 backend/api 拼出双斜杠
      if (v.isEmpty) return null;
      return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final env = Environment(
      id: widget.existing?.id ?? 'env_$now',
      name: name,
      backendUrl: cleanOrNull(_backendCtl),
      supabaseUrl: cleanOrNull(_supabaseCtl),
      minioUrl: cleanOrNull(_minioCtl),
      registryUrl: cleanOrNull(_registryCtl),
      imApiUrl: cleanOrNull(_imApiCtl),
      imWsUrl: cleanOrNull(_imWsCtl),
      configCenterUrl: cleanOrNull(_configCenterCtl),
      isBuiltin: false,
      createdAtMillis: widget.existing?.createdAtMillis ?? now,
    );

    await EnvironmentService.instance.save(env);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '新建环境' : '编辑环境'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameCtl,
              decoration: const InputDecoration(
                labelText: '环境名称',
                hintText: '如：测试服 A',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
            ),
            const SizedBox(height: 16),
            Text(
              '以下 7 个域名留空将回退到生产默认值（即 placeholder 显示的值）。',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            _urlField(_backendCtl, 'Backend (主后端)', 'https://myapp-backend.dapangyu.work'),
            _urlField(_supabaseCtl, 'Supabase 鉴权', 'https://myapp-auth.dapangyu.work'),
            _urlField(_minioCtl, 'MinIO 对象存储', 'https://myapp-oss-endpoint.dapangyu.work'),
            _urlField(_registryCtl, 'Registry 组件市场', 'https://myapp-registry.dapangyu.work'),
            _urlField(_imApiCtl, 'OpenIM HTTP', 'https://myapp-im.dapangyu.work'),
            _urlField(_imWsCtl, 'OpenIM WebSocket', 'wss://myapp-im.dapangyu.work', allowWs: true),
            _urlField(_configCenterCtl, '配置中心', 'https://config.dapangyu.work'),
          ],
        ),
      ),
    );
  }

  Widget _urlField(TextEditingController ctl, String label, String hint, {bool allowWs = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctl,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        validator: (v) => _validateUrl(v, allowWs: allowWs),
      ),
    );
  }
}
