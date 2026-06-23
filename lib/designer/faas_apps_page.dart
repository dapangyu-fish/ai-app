import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';

/// B3-G8: client-side Owner self-management for FaaS "Applications".
///
/// Lets a logged-in Owner see and manage their own applications — the bound FaaS
/// services and the "database" (the per-app schema, shown as a database with its
/// storage usage), plus the access policy (D3 ladder), maintainers, and granted
/// consumers. All calls are owner-scoped server-side (/api/faas/apps*). The DB
/// view is read-only and never exposes a DSN.
class FaasAppsPage extends StatefulWidget {
  const FaasAppsPage({super.key});

  @override
  State<FaasAppsPage> createState() => _FaasAppsPageState();
}

class _FaasAppsPageState extends State<FaasAppsPage> {
  List<Map<String, dynamic>> _apps = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _base => AppConfig.backendUrl;

  Map<String, String> get _headers {
    final h = {'Content-Type': 'application/json'};
    final t = AuthService.token;
    if (t != null) h['Authorization'] = 'Bearer $t';
    return h;
  }

  Future<http.Response> _req(String method, String path, {Map<String, dynamic>? body}) {
    final uri = Uri.parse('$_base$path');
    final b = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'POST':
        return http.post(uri, headers: _headers, body: b);
      case 'DELETE':
        return http.delete(uri, headers: _headers, body: b);
      default:
        return http.get(uri, headers: _headers);
    }
  }

  Map<String, dynamic> _obj(http.Response r) {
    try {
      final d = jsonDecode(r.body);
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    if (!AuthService.isLoggedIn) return;
    setState(() => _loading = true);
    try {
      final r = await _req('GET', '/api/faas/apps');
      final d = _obj(r);
      if (r.statusCode >= 400) throw Exception(d['error'] ?? 'HTTP ${r.statusCode}');
      final raw = d['applications'] as List<dynamic>? ?? const [];
      if (!mounted) return;
      setState(() => _apps = raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList());
    } catch (e) {
      _snack('加载应用失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的应用 (FaaS)'),
        actions: [
          IconButton(
            tooltip: 'FaaS 服务 (配额 / 删除)',
            onPressed: !AuthService.isLoggedIn
                ? null
                : () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const _FaasServicesPage())),
            icon: const Icon(Icons.dns_outlined),
          ),
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: !AuthService.isLoggedIn
          ? const Center(child: Text('请先登录'))
          : RefreshIndicator(
              onRefresh: _load,
              child: _apps.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      Center(child: Text('暂无应用')),
                    ])
                  : ListView.separated(
                      itemCount: _apps.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final a = _apps[i];
                        final policy = (a['access_policy'] ?? 'owner-only').toString();
                        return ListTile(
                          title: Text((a['name'] ?? a['app_id'] ?? '').toString()),
                          subtitle: Text('${a['app_id']}\n访问策略: $policy'),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _FaasAppDetailPage(
                              appId: (a['app_id'] ?? '').toString(),
                              req: _req,
                              obj: _obj,
                            ),
                          )).then((_) => _load()),
                        );
                      },
                    ),
            ),
    );
  }
}

class _FaasAppDetailPage extends StatefulWidget {
  final String appId;
  final Future<http.Response> Function(String, String, {Map<String, dynamic>? body}) req;
  final Map<String, dynamic> Function(http.Response) obj;
  const _FaasAppDetailPage({required this.appId, required this.req, required this.obj});

  @override
  State<_FaasAppDetailPage> createState() => _FaasAppDetailPageState();
}

class _FaasAppDetailPageState extends State<_FaasAppDetailPage> {
  Map<String, dynamic> _detail = const {};
  bool _loading = false;
  static const _policies = ['owner-only', 'allowlist', 'install-required', 'public'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await widget.req('GET', '/api/faas/apps/${widget.appId}');
      final d = widget.obj(r);
      if (r.statusCode >= 400) throw Exception(d['error'] ?? 'HTTP ${r.statusCode}');
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      _snack('加载详情失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setPolicy(String p) async {
    final r = await widget.req('POST', '/api/faas/apps/${widget.appId}/policy', body: {'access_policy': p});
    if (r.statusCode >= 400) {
      _snack('设置策略失败: ${widget.obj(r)['error']}');
    } else {
      _snack('已设为 $p');
      _load();
    }
  }

  Future<void> _addMember(String path, String label) async {
    final ctrl = TextEditingController();
    final uid = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(label),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '用户 ID')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (uid == null || uid.isEmpty) return;
    final r = await widget.req('POST', '/api/faas/apps/${widget.appId}$path', body: {'target_user_id': uid});
    if (r.statusCode >= 400) {
      _snack('失败: ${widget.obj(r)['error']}');
    } else {
      _load();
    }
  }

  Future<void> _removeMember(String path) async {
    final r = await widget.req('DELETE', '/api/faas/apps/${widget.appId}$path');
    if (r.statusCode >= 400) {
      _snack('失败: ${widget.obj(r)['error']}');
    } else {
      _load();
    }
  }

  Future<void> _deleteService(String serviceId) async {
    if (serviceId.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这个 FaaS 服务'),
        content: Text('仅永久删除服务「$serviceId」（停容器 + 删记录 + 删代码，释放一个配额），'
            '不影响本应用的其他服务与数据库。此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除此服务'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await widget.req('DELETE', '/api/faas/services/$serviceId?purge=1');
    if (r.statusCode >= 400) {
      _snack('删除失败: ${widget.obj(r)['error']}');
    } else {
      _snack('已删除服务: $serviceId');
      _load();
    }
  }

  Future<void> _deleteApp() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除整个应用'),
        content: const Text('将删除该应用下的【所有】FaaS 服务和数据库（不可恢复）。'
            '若只想删其中某一个服务，请点下面服务列表里每条右侧的删除按钮。确定删除整个应用？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await widget.req('DELETE', '/api/faas/apps/${widget.appId}');
    if (r.statusCode >= 400) {
      _snack('删除失败: ${widget.obj(r)['error']}');
    } else {
      if (mounted) Navigator.pop(context);
    }
  }

  String _fmtBytes(num b) {
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(1)} KB';
    return '$b B';
  }

  @override
  Widget build(BuildContext context) {
    final app = (_detail['application'] as Map?)?.cast<String, dynamic>() ?? const {};
    final services = (_detail['services'] as List?)?.whereType<Map>().toList() ?? const [];
    final maintainers = (_detail['maintainers'] as List?)?.whereType<Map>().toList() ?? const [];
    final consumers = (_detail['consumers'] as List?)?.whereType<Map>().toList() ?? const [];
    final storage = (_detail['storage_bytes'] as num?) ?? 0;
    final policy = (app['access_policy'] ?? 'owner-only').toString();

    return Scaffold(
      appBar: AppBar(
        title: Text((app['name'] ?? widget.appId).toString()),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: _deleteApp, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Privacy disclosure (B3-G6 / D4a)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('提示：作为应用所有者/维护者，你可以访问本应用内消费者创建的数据。',
                  style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('访问策略'),
            trailing: DropdownButton<String>(
              value: _policies.contains(policy) ? policy : 'owner-only',
              items: _policies.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
              onChanged: (v) => v == null ? null : _setPolicy(v),
            ),
          ),
          const Divider(),
          _sectionTitle('数据库 (schema)'),
          ListTile(title: const Text('存储用量'), trailing: Text(_fmtBytes(storage))),
          const Divider(),
          _sectionTitle('FaaS 服务 (${services.length}) — 可单独删除'),
          ...services.map((s) => ListTile(
                dense: true,
                title: Text((s['service_id'] ?? '').toString()),
                subtitle: Text('状态: ${s['status']}  实例: ${s['running_replicas'] ?? 0}'),
                trailing: IconButton(
                  tooltip: '只删除这个服务',
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _deleteService((s['service_id'] ?? '').toString()),
                ),
              )),
          const Divider(),
          _sectionTitle('维护者 (${maintainers.length})', onAdd: () => _addMember('/maintainers', '添加维护者')),
          ...maintainers.map((m) => ListTile(
                dense: true,
                title: Text((m['user_id'] ?? '').toString()),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _removeMember('/maintainers/${m['user_id']}'),
                ),
              )),
          const Divider(),
          _sectionTitle('授权消费者 (${consumers.length})', onAdd: () => _addMember('/grants', '授权消费者')),
          ...consumers.map((c) => ListTile(
                dense: true,
                title: Text((c['user_id'] ?? '').toString()),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _removeMember('/grants/${c['user_id']}'),
                ),
              )),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t, {VoidCallback? onAdd}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold))),
            if (onAdd != null) IconButton(icon: const Icon(Icons.add), onPressed: onAdd),
          ],
        ),
      );
}

/// Raw FaaS service manager: lists the owner's services (the unit the
/// `FAAS_MAX_SERVICES_PER_USER` quota counts) and lets them be permanently
/// deleted (purge) to free a slot. Without this, a user who hit the quota could
/// never create another service. Owner-scoped server-side via /api/faas/services.
class _FaasServicesPage extends StatefulWidget {
  const _FaasServicesPage();

  @override
  State<_FaasServicesPage> createState() => _FaasServicesPageState();
}

class _FaasServicesPageState extends State<_FaasServicesPage> {
  List<Map<String, dynamic>> _services = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _base => AppConfig.backendUrl;

  Map<String, String> get _headers {
    final h = {'Content-Type': 'application/json'};
    final t = AuthService.token;
    if (t != null) h['Authorization'] = 'Bearer $t';
    return h;
  }

  Map<String, dynamic> _obj(http.Response r) {
    try {
      final d = jsonDecode(r.body);
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    if (!AuthService.isLoggedIn) return;
    setState(() => _loading = true);
    try {
      final r = await http.get(Uri.parse('$_base/api/faas/services'), headers: _headers);
      final d = _obj(r);
      if (r.statusCode >= 400) throw Exception(d['error'] ?? 'HTTP ${r.statusCode}');
      final raw = d['services'] as List<dynamic>? ?? const [];
      if (!mounted) return;
      setState(() => _services =
          raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList());
    } catch (e) {
      _snack('加载服务失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete(String serviceId, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 FaaS 服务'),
        content: Text(
            '确定永久删除「$label」吗？\n\n这会停止并彻底移除该服务（含代码与数据库 schema），并释放一个服务配额。此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _loading = true);
    try {
      final r = await http.delete(
          Uri.parse('$_base/api/faas/services/$serviceId?purge=1'),
          headers: _headers);
      final d = _obj(r);
      if (r.statusCode >= 400) throw Exception(d['error'] ?? 'HTTP ${r.statusCode}');
      _snack('已删除：$label');
      await _load();
    } catch (e) {
      _snack('删除失败: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('FaaS 服务 (${_services.length})'),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: !AuthService.isLoggedIn
          ? const Center(child: Text('请先登录'))
          : RefreshIndicator(
              onRefresh: _load,
              child: _services.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      Center(child: Text('暂无 FaaS 服务')),
                    ])
                  : ListView.separated(
                      itemCount: _services.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = _services[i];
                        final id = (s['service_id'] ?? '').toString();
                        final slug = (s['slug'] ?? s['name'] ?? id).toString();
                        final status = (s['status'] ?? '').toString();
                        return ListTile(
                          title: Text(slug),
                          subtitle: Text('$id\n状态: $status'),
                          isThreeLine: true,
                          trailing: IconButton(
                            tooltip: '删除服务',
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed:
                                _loading || id.isEmpty ? null : () => _delete(id, slug),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
