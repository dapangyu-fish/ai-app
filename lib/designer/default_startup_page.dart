// 默认启动 App 选择页
//
// 三段：
//   1. 顶部一项：不设置（即默认 MyApp 首页行为）
//   2. Tab 切到「市场」：从 registry /packages?type=app 拉，过滤掉 lib
//   3. Tab 切到「本地」：从 AppStorage 拉 SavedApp 列表
//
// 选中后立即写 SharedPreferences + toast「已设置」+ pop 回设置页

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../i18n/framework_strings.dart';
import '../i18n/locale_controller.dart';
import 'app_storage.dart';
import 'default_startup_prefs.dart';

class DefaultStartupPage extends StatefulWidget {
  const DefaultStartupPage({super.key});

  @override
  State<DefaultStartupPage> createState() => _DefaultStartupPageState();
}

class _DefaultStartupPageState extends State<DefaultStartupPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  DefaultStartupConfig _current = const DefaultStartupConfig.none();

  // market
  bool _marketLoading = true;
  String? _marketError;
  List<Map<String, dynamic>> _marketApps = const [];

  // local
  bool _localLoading = true;
  List<SavedApp> _localApps = const [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cur = await DefaultStartupPrefs.read();
    if (mounted) setState(() => _current = cur);
    // 切到当前选中的 tab，让用户立刻看到自己之前选的那个
    if (cur.kind == DefaultStartupKind.local) {
      _tab.animateTo(1);
    }
    await Future.wait([_loadMarket(), _loadLocal()]);
  }

  Future<void> _loadMarket() async {
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.registryUrl}/packages?type=app'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final pkgs = (data['packages'] as List<dynamic>).cast<Map<String, dynamic>>();
      // registry 已经按 type=app 过滤过 lib，这里多保险一层
      final apps = pkgs.where((p) => (p['type'] ?? 'app') == 'app').toList();
      if (!mounted) return;
      setState(() {
        _marketApps = apps;
        _marketLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _marketError = e.toString();
        _marketLoading = false;
      });
    }
  }

  Future<void> _loadLocal() async {
    final list = await AppStorage.instance.list();
    if (!mounted) return;
    setState(() {
      _localApps = list;
      _localLoading = false;
    });
  }

  Future<void> _selectNone() async {
    await DefaultStartupPrefs.writeNone();
    if (!mounted) return;
    final s = T.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.defaultStartupSavedToast)));
    Navigator.of(context).pop();
  }

  Future<void> _selectMarket(Map<String, dynamic> app) async {
    final name = app['name'] as String;
    final version = app['version'] as String;
    // 优先取 displayName（多语言）；否则用 name 兜底
    final dn = (app['displayName'] is Map<String, dynamic>)
        ? _pickDisplayName(app['displayName'] as Map<String, dynamic>) ?? name
        : (app['displayName']?.toString() ?? name);
    await DefaultStartupPrefs.writeMarket(
      name: name,
      version: version,
      displayName: dn,
    );
    if (!mounted) return;
    final s = T.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.defaultStartupSavedToast)));
    Navigator.of(context).pop();
  }

  Future<void> _selectLocal(SavedApp app) async {
    await DefaultStartupPrefs.writeLocal(
      fileName: app.fileName,
      displayName: app.name,
    );
    if (!mounted) return;
    final s = T.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.defaultStartupSavedToast)));
    Navigator.of(context).pop();
  }

  String? _pickDisplayName(Map<String, dynamic> dn) {
    // displayName 可以是 {zh: "...", en: "..."} 这种结构（registry 里见过）
    // 取当前 locale 优先；找不到就第一个非空值
    final tag = LocaleController.currentLocaleTag(); // e.g. "zh-CN" / "en"
    final isZh = tag.startsWith('zh');
    final preferred = isZh ? 'zh' : 'en';
    final fallback = isZh ? 'en' : 'zh';
    final v1 = dn[preferred]?.toString();
    if (v1 != null && v1.isNotEmpty) return v1;
    final v2 = dn[fallback]?.toString();
    if (v2 != null && v2.isNotEmpty) return v2;
    for (final v in dn.values) {
      final s = v?.toString();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = T.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.defaultStartupTitle),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: s.defaultStartupTabMarket),
            Tab(text: s.defaultStartupTabLocal),
          ],
        ),
      ),
      body: Column(
        children: [
          // 顶部说明 + "不设置"项
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              s.defaultStartupHint,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          RadioListTile<bool>(
            value: true,
            groupValue: _current.kind == DefaultStartupKind.none,
            onChanged: (_) => _selectNone(),
            title: Text(s.defaultStartupNoneOption),
            secondary: const Icon(Icons.home_outlined),
          ),
          const Divider(height: 1),

          // Tab 内容
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildMarketList(s, cs),
                _buildLocalList(s, cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarketList(FrameworkStrings s, ColorScheme cs) {
    if (_marketLoading) return const Center(child: CircularProgressIndicator());
    if (_marketError != null) {
      return Center(child: Text(_marketError!, style: TextStyle(color: cs.error)));
    }
    if (_marketApps.isEmpty) {
      return Center(child: Text(s.defaultStartupEmptyMarket, style: TextStyle(color: cs.onSurfaceVariant)));
    }
    return ListView.separated(
      itemCount: _marketApps.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final app = _marketApps[i];
        final name = app['name']?.toString() ?? '';
        final version = app['version']?.toString() ?? '';
        final dn = (app['displayName'] is Map<String, dynamic>)
            ? _pickDisplayName(app['displayName'] as Map<String, dynamic>) ?? name
            : (app['displayName']?.toString() ?? name);
        final selected = _current.kind == DefaultStartupKind.market &&
            _current.marketName == name;
        return RadioListTile<bool>(
          value: true,
          groupValue: selected,
          onChanged: (_) => _selectMarket(app),
          title: Text(dn),
          subtitle: Text('$name · v$version', style: const TextStyle(fontSize: 11)),
        );
      },
    );
  }

  Widget _buildLocalList(FrameworkStrings s, ColorScheme cs) {
    if (_localLoading) return const Center(child: CircularProgressIndicator());
    if (_localApps.isEmpty) {
      return Center(child: Text(s.defaultStartupEmptyLocal, style: TextStyle(color: cs.onSurfaceVariant)));
    }
    return ListView.separated(
      itemCount: _localApps.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final app = _localApps[i];
        final selected = _current.kind == DefaultStartupKind.local &&
            _current.localFileName == app.fileName;
        return RadioListTile<bool>(
          value: true,
          groupValue: selected,
          onChanged: (_) => _selectLocal(app),
          title: Text(app.name),
          subtitle: Text(
            app.fileName,
            style: const TextStyle(fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}
