// 默认启动 App 选择页
//
// 风格跟"市场"和"我的 APP"页面一致：
//   - Card + 48 圆角图标 + 名称 + version chip + 描述 + 作者
//   - 右侧不是"运行"，而是"设为启动 App"按钮（已选中时显示"当前启动 App"灰禁用）
//
// 顶部一项是「不设置（启动到 MyApp 首页）」，点击直接清空设置。
// Tab 切「市场」/「本地」。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../i18n/framework_strings.dart';
import '../i18n/meta_helper.dart';
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

  bool _marketLoading = true;
  String? _marketError;
  List<Map<String, dynamic>> _marketApps = const [];

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
    if (cur.kind == DefaultStartupKind.local) _tab.animateTo(1);
    await Future.wait([_loadMarket(), _loadLocal()]);
  }

  Future<void> _loadMarket() async {
    try {
      final resp = await http
          .get(
            Uri.parse('${AppConfig.registryUrl}/packages').replace(
              queryParameters: {
                'type': 'app',
                'page': '1',
                'per_page': '100',
                'namespace': '/',
              },
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final pkgs = (data['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
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
    await _afterSet();
  }

  Future<void> _selectMarket(Map<String, dynamic> app) async {
    final name = app['name'] as String;
    final version = app['version'] as String;
    final dn = resolveDisplayName(app, fallback: name);
    await DefaultStartupPrefs.writeMarket(
      name: name,
      version: version,
      displayName: dn,
    );
    await _afterSet();
  }

  Future<void> _selectLocal(SavedApp app) async {
    final meta = app.config['meta'] as Map<String, dynamic>?;
    final dn = resolveDisplayName(meta, fallback: app.name);
    await DefaultStartupPrefs.writeLocal(
      fileName: app.fileName,
      displayName: dn,
    );
    await _afterSet();
  }

  Future<void> _afterSet() async {
    if (!mounted) return;
    final s = T.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.defaultStartupSavedToast)));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = T.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.defaultStartupTitle,
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _tab,
            tabs: [
              Tab(text: s.defaultStartupTabMarket),
              Tab(text: s.defaultStartupTabLocal),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // 顶部说明 + "不设置"卡片
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              s.defaultStartupHint,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _NoneCard(
              isCurrent: _current.kind == DefaultStartupKind.none,
              onSelect: _selectNone,
              s: s,
              cs: cs,
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [_buildMarketList(s, cs), _buildLocalList(s, cs)],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────── Market ───────────

  Widget _buildMarketList(FrameworkStrings s, ColorScheme cs) {
    if (_marketLoading) return const Center(child: CircularProgressIndicator());
    if (_marketError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _marketError!,
            style: TextStyle(color: cs.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_marketApps.isEmpty) {
      return Center(
        child: Text(
          s.defaultStartupEmptyMarket,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _marketApps.length,
      itemBuilder: (_, i) {
        final app = _marketApps[i];
        final name = app['name']?.toString() ?? '';
        final dn = resolveDisplayName(app, fallback: name);
        final desc = app['description']?.toString() ?? '';
        final version = app['version']?.toString() ?? '';
        final author = app['author']?.toString() ?? '';
        final isCurrent =
            _current.kind == DefaultStartupKind.market &&
            _current.marketName == name;

        return _AppCard(
          displayName: dn,
          subtitle: name,
          description: desc,
          version: version,
          author: author,
          isCurrent: isCurrent,
          onSelect: () => _selectMarket(app),
          s: s,
          cs: cs,
        );
      },
    );
  }

  // ─────────── Local ───────────

  Widget _buildLocalList(FrameworkStrings s, ColorScheme cs) {
    if (_localLoading) return const Center(child: CircularProgressIndicator());
    if (_localApps.isEmpty) {
      return Center(
        child: Text(
          s.defaultStartupEmptyLocal,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _localApps.length,
      itemBuilder: (_, i) {
        final app = _localApps[i];
        final meta = app.config['meta'] as Map<String, dynamic>?;
        final dn = resolveDisplayName(meta, fallback: app.name);
        final version = (meta?['version'])?.toString() ?? '';
        final author = (meta?['author'])?.toString() ?? '';
        final isCurrent =
            _current.kind == DefaultStartupKind.local &&
            _current.localFileName == app.fileName;

        return _AppCard(
          displayName: dn,
          subtitle: app.fileName,
          description: app.description,
          version: version,
          author: author,
          isCurrent: isCurrent,
          onSelect: () => _selectLocal(app),
          s: s,
          cs: cs,
        );
      },
    );
  }
}

/// 单个 App 卡片：跟市场页 _buildAppCard 同款 layout，右侧加"设为启动 App"按钮
class _AppCard extends StatelessWidget {
  final String displayName;
  final String subtitle;
  final String description;
  final String version;
  final String author;
  final bool isCurrent;
  final VoidCallback onSelect;
  final FrameworkStrings s;
  final ColorScheme cs;

  const _AppCard({
    required this.displayName,
    required this.subtitle,
    required this.description,
    required this.version,
    required this.author,
    required this.isCurrent,
    required this.onSelect,
    required this.s,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isCurrent
            ? BorderSide(color: cs.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.apps, color: cs.onSurface, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (version.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'v$version',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (author.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      T.fmt(s.marketAuthor, {'author': author}),
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ] else if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: isCurrent
                        ? OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 16,
                            ),
                            label: Text(s.defaultStartupCurrent),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: onSelect,
                            icon: const Icon(
                              Icons.rocket_launch_outlined,
                              size: 16,
                            ),
                            label: Text(s.defaultStartupSetAsStartup),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部"不设置"卡片
class _NoneCard extends StatelessWidget {
  final bool isCurrent;
  final VoidCallback onSelect;
  final FrameworkStrings s;
  final ColorScheme cs;

  const _NoneCard({
    required this.isCurrent,
    required this.onSelect,
    required this.s,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isCurrent
            ? BorderSide(color: cs.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.home_outlined, color: cs.onSurface, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                s.defaultStartupNoneOption,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            isCurrent
                ? OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: Text(s.defaultStartupCurrent),
                  )
                : FilledButton.tonalIcon(
                    onPressed: onSelect,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(s.defaultStartupResetToNone),
                  ),
          ],
        ),
      ),
    );
  }
}
