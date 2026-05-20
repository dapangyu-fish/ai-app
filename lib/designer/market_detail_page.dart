// 市场 App 详情页 + 用户主页
// ─────────────────────────────────────────────────────────
// - MarketAppDetailPage: 点市场卡片进，展示作者(头像可点)/summary/tech_stack/
//   点赞下载量/运行按钮。运行=pop 返回 'run' 让市场加载 + 发 install 埋点。
// - MarketUserProfilePage: 点作者进，展示总下载/总点赞 + 他的 app 列表。
//
// 数据来自 registry: GET /packages/<name>/detail、GET /users/<id>/profile。
// 点赞/install 走 POST，带 AuthService.token。

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import 'market_favorites.dart';

bool _isZh(BuildContext ctx) =>
    Localizations.localeOf(ctx).languageCode.toLowerCase().startsWith('zh');

/// 双语 summary 按 locale 选
String _pickSummary(BuildContext ctx, Map<String, dynamic> d) {
  final zh = (d['summary_zh'] as String?) ?? '';
  final en = (d['summary_en'] as String?) ?? '';
  if (_isZh(ctx)) return zh.isNotEmpty ? zh : en;
  return en.isNotEmpty ? en : zh;
}

// ════════════════════════════════════════════════════════
// App 详情页
// ════════════════════════════════════════════════════════

class MarketAppDetailPage extends StatefulWidget {
  /// 市场列表传来的包基础信息（name/version/download_url 等），运行时透传给加载逻辑
  final Map<String, dynamic> app;
  const MarketAppDetailPage({super.key, required this.app});

  @override
  State<MarketAppDetailPage> createState() => _MarketAppDetailPageState();
}

class _MarketAppDetailPageState extends State<MarketAppDetailPage> {
  Map<String, dynamic>? _detail;
  bool _loading = true;
  bool _likeBusy = false;
  bool _favorited = false;

  String get _name => widget.app['name']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _fetchDetail();
    _loadFavorite();
  }

  Future<void> _loadFavorite() async {
    final f = await MarketFavorites.isFavorite(_name);
    if (mounted) setState(() => _favorited = f);
  }

  Future<void> _toggleFavorite() async {
    final displayName = widget.app['name']?.toString() ?? _name;
    final now = await MarketFavorites.toggle(_name, displayName);
    if (mounted) setState(() => _favorited = now);
  }

  Future<void> _fetchDetail() async {
    setState(() => _loading = true);
    try {
      final headers = <String, String>{};
      final token = AuthService.token;
      if (token != null) headers['Authorization'] = 'Bearer $token';
      final resp = await http
          .get(Uri.parse('${AppConfig.registryUrl}/packages/$_name/detail'),
              headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _detail = json.decode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggleLike() async {
    final token = AuthService.token;
    if (token == null || _detail == null || _likeBusy) return;
    final liked = _detail!['liked_by_me'] == true;
    setState(() {
      _likeBusy = true;
      _detail!['liked_by_me'] = !liked;
      _detail!['like_count'] = (_detail!['like_count'] ?? 0) + (liked ? -1 : 1);
    });
    try {
      final uri = Uri.parse('${AppConfig.registryUrl}/packages/$_name/like');
      final headers = {'Authorization': 'Bearer $token'};
      final resp = liked
          ? await http.delete(uri, headers: headers).timeout(const Duration(seconds: 8))
          : await http.post(uri, headers: headers).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) throw Exception('like ${resp.statusCode}');
    } catch (_) {
      // 失败回滚
      if (mounted) {
        setState(() {
          _detail!['liked_by_me'] = liked;
          _detail!['like_count'] = (_detail!['like_count'] ?? 0) + (liked ? 1 : -1);
        });
      }
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _run() async {
    // 发 install 埋点（fire-and-forget），然后 pop 返回 'run' 让市场加载
    final token = AuthService.token;
    if (token != null) {
      // ignore: unawaited_futures
      http.post(
        Uri.parse('${AppConfig.registryUrl}/packages/$_name/install'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 0));
    }
    if (mounted) Navigator.of(context).pop('run');
  }

  void _openAuthor() {
    final author = _detail?['author'] as Map<String, dynamic>?;
    final authorId = author?['id']?.toString();
    if (authorId == null || authorId.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MarketUserProfilePage(authorId: authorId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = _detail;
    final displayName = widget.app['name']?.toString() ?? '';
    final version = widget.app['version']?.toString() ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(_isZh(context) ? '详情' : 'Details'),
        actions: [
          IconButton(
            tooltip: _isZh(context) ? '收藏' : 'Favorite',
            icon: Icon(_favorited ? Icons.bookmark : Icons.bookmark_border,
                color: _favorited ? cs.primary : null),
            onPressed: _toggleFavorite,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // 头部：icon + 名字 + version
                Row(
                  children: [
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.apps, color: cs.onSurface, size: 32),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayName,
                              style: GoogleFonts.inter(
                                  fontSize: 20, fontWeight: FontWeight.w700,
                                  color: cs.onSurface)),
                          if (version.isNotEmpty)
                            Text('v$version',
                                style: TextStyle(
                                    fontSize: 13, color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // 作者行（头像可点 → 用户主页）
                if (d?['author'] != null) _authorRow(d!['author'], cs),
                const SizedBox(height: 20),

                // 点赞 / 下载量
                Row(
                  children: [
                    _statChip(
                      icon: (d?['liked_by_me'] == true)
                          ? Icons.favorite : Icons.favorite_border,
                      label: '${d?['like_count'] ?? 0}',
                      color: (d?['liked_by_me'] == true) ? Colors.red : cs.onSurfaceVariant,
                      onTap: AuthService.token != null ? _toggleLike : null,
                      cs: cs,
                    ),
                    const SizedBox(width: 12),
                    _statChip(
                      icon: Icons.download_outlined,
                      label: '${d?['install_count'] ?? 0}',
                      color: cs.onSurfaceVariant,
                      cs: cs,
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // summary
                if (d != null && _pickSummary(context, d).isNotEmpty) ...[
                  Text(_isZh(context) ? '简介' : 'About',
                      style: GoogleFonts.inter(
                          fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                  const SizedBox(height: 6),
                  Text(_pickSummary(context, d),
                      style: TextStyle(fontSize: 14, height: 1.5, color: cs.onSurface)),
                  const SizedBox(height: 20),
                ],

                // tech_stack 芯片
                if (d?['tech_stack'] is List && (d!['tech_stack'] as List).isNotEmpty) ...[
                  Text(_isZh(context) ? '技术栈' : 'Tech stack',
                      style: GoogleFonts.inter(
                          fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: [
                      for (final t in (d['tech_stack'] as List))
                        Chip(label: Text(t.toString(), style: const TextStyle(fontSize: 12))),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],

                // capabilities
                if (d?['capabilities'] is List && (d!['capabilities'] as List).isNotEmpty) ...[
                  Text(_isZh(context) ? '功能' : 'Features',
                      style: GoogleFonts.inter(
                          fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                  const SizedBox(height: 6),
                  for (final c in (d['capabilities'] as List))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('· ', style: TextStyle(color: cs.onSurfaceVariant)),
                        Expanded(child: Text(c.toString(),
                            style: TextStyle(fontSize: 14, color: cs.onSurface))),
                      ]),
                    ),
                  const SizedBox(height: 24),
                ],
              ],
            ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: FilledButton.icon(
                  onPressed: _run,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_isZh(context) ? '运行' : 'Run',
                      style: const TextStyle(fontSize: 16)),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50)),
                ),
              ),
            ),
    );
  }

  Widget _authorRow(Map<String, dynamic> author, ColorScheme cs) {
    final nickname = author['nickname']?.toString() ?? '';
    final avatar = author['avatar_url']?.toString() ?? '';
    return InkWell(
      onTap: _openAuthor,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: cs.primaryContainer,
              backgroundImage: avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
              child: avatar.isEmpty
                  ? Text(nickname.isNotEmpty ? nickname[0].toUpperCase() : '?',
                      style: TextStyle(color: cs.onPrimaryContainer))
                  : null,
            ),
            const SizedBox(width: 10),
            Text(nickname.isEmpty ? (_isZh(context) ? '未知作者' : 'Unknown') : nickname,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
            Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _statChip({required IconData icon, required String label,
      required Color color, VoidCallback? onTap, required ColorScheme cs}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 14, color: cs.onSurface)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// 用户主页
// ════════════════════════════════════════════════════════

class MarketUserProfilePage extends StatefulWidget {
  final String authorId;
  const MarketUserProfilePage({super.key, required this.authorId});

  @override
  State<MarketUserProfilePage> createState() => _MarketUserProfilePageState();
}

class _MarketUserProfilePageState extends State<MarketUserProfilePage> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.registryUrl}/users/${widget.authorId}/profile'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _profile = json.decode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _profile;
    final author = p?['author'] as Map<String, dynamic>?;
    final nickname = author?['nickname']?.toString() ?? '';
    final avatar = author?['avatar_url']?.toString() ?? '';
    final apps = (p?['apps'] as List?) ?? [];

    return Scaffold(
      appBar: AppBar(title: Text(_isZh(context) ? '作者主页' : 'Author')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // 头像 + 名字
                Center(
                  child: Column(children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: cs.primaryContainer,
                      backgroundImage: avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
                      child: avatar.isEmpty
                          ? Text(nickname.isNotEmpty ? nickname[0].toUpperCase() : '?',
                              style: TextStyle(color: cs.onPrimaryContainer, fontSize: 28))
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Text(nickname.isEmpty ? (_isZh(context) ? '未知作者' : 'Unknown') : nickname,
                        style: GoogleFonts.inter(
                            fontSize: 20, fontWeight: FontWeight.w700, color: cs.onSurface)),
                  ]),
                ),
                const SizedBox(height: 24),

                // 总下载 / 总点赞
                Row(children: [
                  Expanded(child: _bigStat(_isZh(context) ? '总下载' : 'Downloads',
                      '${p?['total_installs'] ?? 0}', Icons.download_outlined, cs)),
                  const SizedBox(width: 12),
                  Expanded(child: _bigStat(_isZh(context) ? '总点赞' : 'Likes',
                      '${p?['total_likes'] ?? 0}', Icons.favorite, cs)),
                ]),
                const SizedBox(height: 24),

                Text(_isZh(context) ? '发布的应用 (${apps.length})' : 'Apps (${apps.length})',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                const SizedBox(height: 8),
                for (final a in apps) _appTile(a as Map<String, dynamic>, cs),
              ],
            ),
    );
  }

  Widget _bigStat(String label, String value, IconData icon, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: [
        Icon(icon, color: cs.primary),
        const SizedBox(height: 6),
        Text(value, style: GoogleFonts.inter(
            fontSize: 22, fontWeight: FontWeight.w700, color: cs.onSurface)),
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _appTile(Map<String, dynamic> a, ColorScheme cs) {
    final name = a['name']?.toString() ?? '';
    final summary = _pickSummary(context, a);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Icons.apps, color: cs.onSurface),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: summary.isEmpty ? null : Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.favorite, size: 14, color: cs.onSurfaceVariant),
          Text(' ${a['like_count'] ?? 0}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ]),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MarketAppDetailPage(app: {'name': name}),
        )),
      ),
    );
  }
}
