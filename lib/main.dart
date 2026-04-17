// JSON Low-Code DSL v3.2 - 主入口
// 使用 Material 3 设计风格，集成 Riverpod 状态管理
// 启动页为文件选择器，选择 JSON 文件后加载渲染 Server-Driven UI
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'json_ui/interpreter.dart';
import 'json_ui/widgets/screen_layout.dart';
import 'json_ui/widgets/icon_registry.dart';
import 'designer/designer_ball.dart';
import 'auth/auth_service.dart';
import 'auth/auth_page.dart';

// ============================================================
// Riverpod Providers
// ============================================================

/// JSON 解释器的全局 Provider
final interpreterProvider = ChangeNotifierProvider<JsonInterpreter>((ref) {
  return JsonInterpreter();
});

// ============================================================
// 入口
// ============================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.restoreSession();
  runApp(
    const ProviderScope(
      child: JsonDslApp(),
    ),
  );
}

/// 应用根组件 — Material 3 主题
class JsonDslApp extends ConsumerWidget {
  const JsonDslApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'JSON DSL v3.2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      // 使用 builder 注入悬浮球，凌驾于所有路由之上
      builder: (context, child) {
        return DesignerBall(child: child ?? const SizedBox.shrink());
      },
      home: const _AuthGate(),
    );
  }
}

/// 根据登录状态决定显示登录页还是主页
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.authNotifier,
      builder: (context, loggedIn, _) {
        if (loggedIn) {
          return const FilePickerPage();
        }
        return AuthPage(
          onAuthSuccess: () {
            // authNotifier 已在 AuthService 内部更新
          },
        );
      },
    );
  }
}

// ============================================================
// 启动页：文件选择器
// ============================================================

/// 启动页面 - 用户选择 JSON 文件后加载并渲染
class FilePickerPage extends ConsumerStatefulWidget {
  const FilePickerPage({super.key});

  @override
  ConsumerState<FilePickerPage> createState() => _FilePickerPageState();
}

class _FilePickerPageState extends ConsumerState<FilePickerPage> {
  bool _loading = false;
  String? _error;
  String? _loadedFileName;

  Future<void> _pickAndLoadJson() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      final filePath = result.files.single.path;
      if (filePath == null) {
        setState(() {
          _loading = false;
          _error = '无法获取文件路径';
        });
        return;
      }

      final file = File(filePath);
      final jsonStr = await file.readAsString();
      final config = json.decode(jsonStr) as Map<String, dynamic>;

      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      await interpreter.executeSteps();

      _loadedFileName = result.files.single.name;

      setState(() => _loading = false);

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => JsonScreenView(fileName: _loadedFileName!),
        ),
      );
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      debugPrint('[JSON DSL] 加载文件失败: $e');
    }
  }

  /// 从市场下载并加载一个 App
  Future<void> _loadFromMarket(Map<String, dynamic> app) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final downloadPath = app['download'] as String;
      final resp = await http
          .get(Uri.parse('http://103.233.254.179:5566$downloadPath'))
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        throw Exception('下载失败 (${resp.statusCode})');
      }

      final config = json.decode(resp.body) as Map<String, dynamic>;
      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      await interpreter.executeSteps();

      _loadedFileName = app['name'] as String;
      setState(() => _loading = false);

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => JsonScreenView(fileName: _loadedFileName!),
        ),
      );
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _openMarket() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MarketPage(onSelect: _loadFromMarket),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('JSON DSL v3.2'),
        centerTitle: true,
        actions: [
          if (AuthService.isLoggedIn)
            PopupMenuButton<String>(
              icon: const Icon(Icons.account_circle),
              onSelected: (value) async {
                if (value == 'profile') {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ProfilePage(),
                    ),
                  );
                } else if (value == 'logout') {
                  await AuthService.signOut();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    AuthService.currentUser?['username'] ??
                        AuthService.currentUser?['email'] ??
                        '',
                    style: TextStyle(color: colorScheme.onSurface),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'profile',
                  child: Row(
                    children: [
                      Icon(Icons.person, size: 18),
                      SizedBox(width: 8),
                      Text('个人资料'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'logout',
                  child: Row(
                    children: [
                      Icon(Icons.logout, size: 18),
                      SizedBox(width: 8),
                      Text('退出登录'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // App 图标
              Icon(
                Icons.code,
                size: 80,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'JSON DSL v3.2',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Server-Driven UI 低代码引擎',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 48),

              // 选择本地文件
              FilledButton.icon(
                onPressed: _loading ? null : _pickAndLoadJson,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.folder_open),
                label: Text(_loading ? '加载中...' : '选择本地文件'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),

              const SizedBox(height: 16),

              // 从市场选择
              OutlinedButton.icon(
                onPressed: _loading ? null : _openMarket,
                icon: const Icon(Icons.store),
                label: const Text('从应用市场选择'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),

              // 错误提示
              if (_error != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: colorScheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 32),
              Text(
                '支持格式：JSON DSL v3.2 配置文件',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 应用市场页面
// ============================================================

class _MarketPage extends StatefulWidget {
  final Future<void> Function(Map<String, dynamic> app) onSelect;

  const _MarketPage({required this.onSelect});

  @override
  State<_MarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends State<_MarketPage> {
  List<Map<String, dynamic>> _apps = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchApps();
  }

  Future<void> _fetchApps() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final resp = await http
          .get(Uri.parse('http://103.233.254.179:5566/app-list'))
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        throw Exception('服务器错误 (${resp.statusCode})');
      }

      final data = json.decode(resp.body) as Map<String, dynamic>;
      final apps = (data['apps'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      setState(() {
        _apps = apps;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('应用市场'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchApps,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off,
                          size: 48, color: colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(_error!,
                          style: TextStyle(color: colorScheme.outline)),
                      const SizedBox(height: 16),
                      FilledButton(
                          onPressed: _fetchApps, child: const Text('重试')),
                    ],
                  ),
                )
              : _apps.isEmpty
                  ? Center(
                      child: Text('暂无可用应用',
                          style: TextStyle(color: colorScheme.outline)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _apps.length,
                      itemBuilder: (context, index) {
                        final app = _apps[index];
                        return _buildAppCard(context, app, colorScheme);
                      },
                    ),
    );
  }

  Widget _buildAppCard(BuildContext context, Map<String, dynamic> app,
      ColorScheme colorScheme) {
    final name = app['name'] as String? ?? '';
    final desc = app['description'] as String? ?? '';
    final version = app['version']?.toString() ?? '';
    final author = app['author'] as String? ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).pop();
          widget.onSelect(app);
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 图标
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.apps,
                    color: colorScheme.onPrimaryContainer, size: 24),
              ),
              const SizedBox(width: 16),
              // 信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (version.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'v$version',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: colorScheme.outline),
                            ),
                          ),
                      ],
                    ),
                    if (desc.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        desc,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '作者: $author',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: colorScheme.outline),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.download, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// JSON 渲染页面
// ============================================================

/// 根据当前 screen ID 渲染对应的 JSON 页面
class JsonScreenView extends ConsumerWidget {
  final String fileName;

  const JsonScreenView({super.key, required this.fileName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interpreter = ref.watch(interpreterProvider);
    final currentScreenId = interpreter.currentScreenId;

    // 注入 globalContext 用于 toast / dialog
    interpreter.globalContext = context;

    // 查找当前 screen 定义
    final screens = interpreter.screens;
    Map<String, dynamic>? screenConfig;
    for (final s in screens) {
      if (s is Map<String, dynamic> && s['id'] == currentScreenId) {
        screenConfig = s;
        break;
      }
    }

    if (screenConfig == null) {
      return Scaffold(
        appBar: AppBar(title: Text(interpreter.appName)),
        body: const Center(child: Text('未找到页面配置')),
      );
    }

    // 设置导航回调
    interpreter.onNavigate = (_) {};

    // Tab 页面：有 tabs 字段时渲染底部导航栏
    final tabs = screenConfig['tabs'] as List<dynamic>?;
    if (tabs != null && tabs.isNotEmpty) {
      return _TabScreenView(
        screenConfig: screenConfig,
        interpreter: interpreter,
        screens: screens,
      );
    }

    // 普通页面
    return _buildRegularScreen(context, screenConfig, interpreter, screens);
  }

  Widget _buildRegularScreen(
    BuildContext context,
    Map<String, dynamic> screenConfig,
    JsonInterpreter interpreter,
    List<dynamic> screens,
  ) {
    final currentScreenId = interpreter.currentScreenId;
    final children = screenConfig['children'] as List<dynamic>? ?? [];
    final hasListWidget = _containsListWidget(children);

    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((childJson) => interpreter.buildWidget(context, childJson))
        .toList();

    final layoutWidget = buildScreenLayout(screenConfig, childWidgets);

    final bgColorStr = screenConfig['backgroundColor'] as String?;
    Color? bgColor;
    if (bgColorStr != null && bgColorStr.startsWith('#')) {
      final hex = bgColorStr.replaceFirst('#', '');
      bgColor = Color(int.parse('FF$hex', radix: 16));
    }

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(screenConfig['title'] ?? interpreter.appName),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (currentScreenId == (screens.first as Map)['id']) {
              Navigator.of(context).pop();
            } else {
              interpreter
                  .navigateTo((screens.first as Map<String, dynamic>)['id']);
            }
          },
        ),
      ),
      body: SafeArea(
        child: hasListWidget
            ? Padding(
                padding: EdgeInsets.all(
                  (screenConfig['padding'] as num?)?.toDouble() ?? 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: childWidgets,
                ),
              )
            : SingleChildScrollView(
                child: layoutWidget,
              ),
      ),
    );
  }

  bool _containsListWidget(List<dynamic> children) {
    for (final child in children) {
      if (child is Map<String, dynamic>) {
        if (child['type'] == 'list') return true;
        final subChildren = child['children'] as List<dynamic>?;
        if (subChildren != null && _containsListWidget(subChildren)) {
          return true;
        }
      }
    }
    return false;
  }
}

// ============================================================
// Tab 页面（底部导航栏）
// ============================================================

class _TabScreenView extends StatefulWidget {
  final Map<String, dynamic> screenConfig;
  final JsonInterpreter interpreter;
  final List<dynamic> screens;

  const _TabScreenView({
    required this.screenConfig,
    required this.interpreter,
    required this.screens,
  });

  @override
  State<_TabScreenView> createState() => _TabScreenViewState();
}

class _TabScreenViewState extends State<_TabScreenView> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = widget.screenConfig['tabs'] as List<dynamic>;
    final title = widget.screenConfig['title'] ?? widget.interpreter.appName;

    final bgColorStr = widget.screenConfig['backgroundColor'] as String?;
    Color? bgColor;
    if (bgColorStr != null && bgColorStr.startsWith('#')) {
      final hex = bgColorStr.replaceFirst('#', '');
      bgColor = Color(int.parse('FF$hex', radix: 16));
    }

    // 当前 tab 配置
    final currentTab = tabs[_currentIndex] as Map<String, dynamic>;
    final tabChildren = currentTab['children'] as List<dynamic>? ?? [];
    final tabBgColorStr = currentTab['backgroundColor'] as String?;

    Color? tabBgColor;
    if (tabBgColorStr != null && tabBgColorStr.startsWith('#')) {
      final hex = tabBgColorStr.replaceFirst('#', '');
      tabBgColor = Color(int.parse('FF$hex', radix: 16));
    }

    // 构建当前 tab 的内容
    final hasListWidget = _containsListWidget(tabChildren);
    final childWidgets = tabChildren
        .whereType<Map<String, dynamic>>()
        .map((childJson) =>
            widget.interpreter.buildWidget(context, childJson))
        .toList();

    final padding =
        (currentTab['padding'] as num?)?.toDouble() ??
        (widget.screenConfig['padding'] as num?)?.toDouble() ??
        0;

    Widget body;
    if (hasListWidget) {
      body = Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: childWidgets,
        ),
      );
    } else {
      body = SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: childWidgets,
          ),
        ),
      );
    }

    // 构建底部导航栏
    final navItems = <BottomNavigationBarItem>[];
    for (final tab in tabs) {
      if (tab is Map<String, dynamic>) {
        final label = tab['label']?.toString() ?? '';
        final iconName = tab['icon']?.toString();
        final iconData = iconName != null
            ? IconRegistry.get(iconName) ?? Icons.circle
            : Icons.circle;
        navItems.add(BottomNavigationBarItem(
          icon: Icon(iconData),
          label: label,
        ));
      }
    }

    return Scaffold(
      backgroundColor: tabBgColor ?? bgColor,
      appBar: AppBar(
        title: Text(currentTab['title']?.toString() ?? title),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: navItems.map((item) {
          return NavigationDestination(
            icon: item.icon,
            label: item.label ?? '',
          );
        }).toList(),
      ),
    );
  }

  bool _containsListWidget(List<dynamic> children) {
    for (final child in children) {
      if (child is Map<String, dynamic>) {
        if (child['type'] == 'list') return true;
        final subChildren = child['children'] as List<dynamic>?;
        if (subChildren != null && _containsListWidget(subChildren)) {
          return true;
        }
      }
    }
    return false;
  }
}
