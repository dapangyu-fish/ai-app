// JSON Low-Code DSL v3.2 - 主入口
// 使用 Material 3 设计风格，集成 Riverpod 状态管理
// 启动页为文件选择器，选择 JSON 文件后加载并渲染 Server-Driven UI
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
import 'designer/settings_page.dart';
import 'designer/app_storage.dart';
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

  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'JSON DSL v3.2',
      navigatorKey: navigatorKey,
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
        return DesignerBall(
          child: child ?? const SizedBox.shrink(),
          getCurrentConfig: () => ProviderScope.containerOf(context).read(interpreterProvider).rawConfig,
          onRunJsonApp: (jsonConfig) async {
            final interpreter = ProviderScope.containerOf(context).read(interpreterProvider);
            try {
              // 保存到本地
              await AppStorage.instance.save(Map<String, dynamic>.from(jsonConfig));
              interpreter.loadConfig(jsonConfig);
              await interpreter.executeSteps();
              final meta = jsonConfig['meta'] as Map<String, dynamic>? ?? {};
              final name = (meta['name'] as String?) ?? 'AI 生成';
              JsonDslApp.navigatorKey.currentState?.push(
                MaterialPageRoute(
                  builder: (_) => JsonScreenView(fileName: name),
                ),
              );
            } catch (e) {
              debugPrint('[DesignerBall] Run JSON-APP error: $e');
            }
          },
        );
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

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SettingsPage(),
      ),
    );
  }

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
          .get(Uri.parse('https://app-backend.dapangyu.work$downloadPath'))
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

  void _openMyApps() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MyAppsPage(onSelect: _loadSavedApp),
      ),
    );
  }

  Future<void> _loadSavedApp(SavedApp app) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(app.config);
      await interpreter.executeSteps();
      _loadedFileName = app.name;
      setState(() => _loading = false);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => JsonScreenView(fileName: app.name),
        ),
      );
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
        title: const Text('JSON DSL v3.2'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
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

              const SizedBox(height: 16),

              // 我的 APP（AI 生成的历史）
              OutlinedButton.icon(
                onPressed: _loading ? null : _openMyApps,
                icon: const Icon(Icons.history),
                label: const Text('我的 APP'),
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
          .get(Uri.parse('https://app-backend.dapangyu.work/app-list'))
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
    // 沙盒 try-catch — 捕获 JSON-APP 运行时崩溃
    try {
      return _buildContent(context, ref);
    } catch (e, stack) {
      return _CrashPage(
        error: e.toString(),
        stackTrace: stack.toString(),
        fileName: fileName,
      );
    }
  }

  Widget _buildContent(BuildContext context, WidgetRef ref) {
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
// 崩溃页面
// ============================================================

class _CrashPage extends StatelessWidget {
  final String error;
  final String stackTrace;
  final String fileName;

  const _CrashPage({
    required this.error,
    required this.stackTrace,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('APP 运行出错'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 48, color: cs.error),
            const SizedBox(height: 12),
            Text('$fileName 运行崩溃',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(error,
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 13)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(stackTrace,
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.onSurface)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      // 把崩溃信息发给 AI 分析（JSON 配置由 DesignerBall 自动注入上下文）
                      final crashMsg = 'JSON-APP 运行崩溃，请分析原因并输出修复后的完整 JSON：\n\n'
                          '## 错误\n$error\n\n'
                          '## 堆栈\n${stackTrace.length > 500 ? stackTrace.substring(0, 500) : stackTrace}';
                      Navigator.of(context).pop();
                      // 通过 DesignerBall 发起 AI 对话
                      DesignerBall.sendCrashReport?.call(crashMsg);
                    },
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('AI 分析修复'),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.tertiary,
                      foregroundColor: cs.onTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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


// ============================================================
// 我的 APP — AI 生成的历史列表
// ============================================================

class _MyAppsPage extends StatefulWidget {
  final void Function(SavedApp app) onSelect;
  const _MyAppsPage({required this.onSelect});

  @override
  State<_MyAppsPage> createState() => _MyAppsPageState();
}

class _MyAppsPageState extends State<_MyAppsPage> {
  List<SavedApp>? _apps;
  bool _uploading = false;

  bool get _isAdmin => AuthService.currentUser?['role'] == 'admin';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apps = await AppStorage.instance.list();
    if (mounted) setState(() => _apps = apps);
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<String?> _showVersionDialog({
    required String existingName,
    required String existingVersion,
    required String suggestedVersion,
  }) {
    final controller = TextEditingController(text: suggestedVersion);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('更新确认'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: Theme.of(ctx).textTheme.bodyMedium,
                  children: [
                    TextSpan(text: existingName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const TextSpan(text: ' 已存在于市场'),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text('当前版本: v$existingVersion', style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 12),
              const Text('这将是一个更新操作，请确认新版本号:'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: '版本号',
                  prefixIcon: const Icon(Icons.tag),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('确认更新'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _uploadToMarket(SavedApp app) async {
    if (_uploading) return;
    setState(() => _uploading = true);

    try {
      final resp = await http.post(
        Uri.parse('https://app-backend.dapangyu.work/api/store/publish'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AuthService.token}',
        },
        body: json.encode({'json_content': app.config}),
      ).timeout(const Duration(seconds: 30));

      final data = json.decode(resp.body) as Map<String, dynamic>;

      if (resp.statusCode == 409 && data['conflict'] == true) {
        final existing = data['existing'] as Map<String, dynamic>;
        final suggestedVersion = data['suggested_version'] as String;

        if (!mounted) return;
        final confirmedVersion = await _showVersionDialog(
          existingName: existing['name'] as String? ?? app.name,
          existingVersion: existing['version'] as String? ?? '1.0.0',
          suggestedVersion: suggestedVersion,
        );

        if (confirmedVersion == null || confirmedVersion.isEmpty) {
          _showSnackBar('已取消上传');
          return;
        }

        final updatedConfig = Map<String, dynamic>.from(app.config);
        final meta = Map<String, dynamic>.from(updatedConfig['meta'] ?? {});
        meta['version'] = confirmedVersion;
        updatedConfig['meta'] = meta;

        final resp2 = await http.post(
          Uri.parse('https://app-backend.dapangyu.work/api/store/publish'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${AuthService.token}',
          },
          body: json.encode({
            'json_content': updatedConfig,
            'force_update': true,
          }),
        ).timeout(const Duration(seconds: 30));

        final data2 = json.decode(resp2.body) as Map<String, dynamic>;
        if (resp2.statusCode == 200) {
          _showSnackBar('更新成功: ${app.name} v$confirmedVersion');
        } else {
          _showSnackBar('更新失败: ${data2['error'] ?? '未知错误'}');
        }
      } else if (resp.statusCode == 200) {
        _showSnackBar('发布成功: ${app.name}');
      } else {
        _showSnackBar('发布失败: ${data['error'] ?? '未知错误'}');
      }
    } catch (e) {
      _showSnackBar('上传失败: ${e.toString().replaceFirst("Exception: ", "")}');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('我的 APP')),
      body: _apps == null
          ? const Center(child: CircularProgressIndicator())
          : _apps!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox, size: 64, color: colorScheme.outline),
                      const SizedBox(height: 16),
                      Text('还没有 APP', style: TextStyle(color: colorScheme.outline, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('长按悬浮球，用语音让 AI 帮你生成', style: TextStyle(color: colorScheme.outline, fontSize: 13)),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _apps!.length,
                      itemBuilder: (context, index) {
                        final app = _apps![index];
                        final time = DateTime.tryParse(app.savedAt);
                        final timeStr = time != null
                            ? '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}'
                            : '';

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: colorScheme.primaryContainer,
                              child: Icon(Icons.apps, color: colorScheme.primary),
                            ),
                            title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              app.description.isNotEmpty ? app.description : timeStr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isAdmin)
                                  IconButton(
                                    icon: Icon(Icons.cloud_upload_outlined,
                                        size: 20, color: colorScheme.primary),
                                    tooltip: '上传到市场',
                                    onPressed: _uploading ? null : () => _uploadToMarket(app),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  onPressed: () async {
                                    await AppStorage.instance.delete(app.fileName);
                                    _load();
                                  },
                                ),
                              ],
                            ),
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onSelect(app);
                            },
                          ),
                        );
                      },
                    ),
                    if (_uploading)
                      Container(
                        color: Colors.black26,
                        child: const Center(
                          child: Card(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('正在上传到市场...'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
