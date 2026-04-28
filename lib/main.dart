import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'json_ui/interpreter.dart';
import 'json_ui/widget_builder.dart';
import 'json_ui/cache_manager.dart';
import 'json_ui/semver.dart';
import 'json_ui/widgets/screen_layout.dart';
import 'json_ui/widgets/icon_registry.dart';
import 'designer/designer_ball.dart';
import 'designer/settings_page.dart';
import 'designer/ai_chat_service.dart';
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

  // 捕捉全局渲染和布局异常（防止布局越界等导致直接白屏）
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'UI 渲染/布局崩溃',
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                details.exception.toString(),
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  };

  await AuthService.restoreSession();
  await AiChatService.loadProvider();
  runApp(
    const ProviderScope(
      child: JsonDslApp(),
    ),
  );
}

/// 应用根组件
class JsonDslApp extends ConsumerWidget {
  const JsonDslApp({super.key});

  static final navigatorKey = GlobalKey<NavigatorState>();

  static TextTheme _buildTextTheme(Brightness brightness) {
    final base = brightness == Brightness.dark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    return GoogleFonts.interTextTheme(base);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'MyApp',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        textTheme: _buildTextTheme(Brightness.light),
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          surface: Colors.white,
          onSurface: Colors.black,
          primary: Colors.black,
          onPrimary: Colors.white,
          secondary: Color(0xFF666666),
          onSecondary: Colors.white,
          surfaceContainerHighest: Color(0xFFF2F2F2),
          surfaceContainerHigh: Color(0xFFF5F5F5),
          surfaceContainer: Color(0xFFF0F0F0),
          outline: Color(0xFFE0E0E0),
          onSurfaceVariant: Color(0xFF666666),
          error: Color(0xFFB00020),
          errorContainer: Color(0xFFFCE4EC),
          onErrorContainer: Color(0xFFB00020),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFFF5F5F5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.black,
            side: const BorderSide(color: Color(0xFFE0E0E0)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: Colors.black,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF2F2F2),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.black, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Colors.black.withValues(alpha: 0.08),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE0E0E0),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        textTheme: _buildTextTheme(Brightness.dark),
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          onSurface: Colors.white,
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Color(0xFF999999),
          onSecondary: Colors.black,
          surfaceContainerHighest: Color(0xFF1A1A1A),
          surfaceContainerHigh: Color(0xFF1A1A1A),
          surfaceContainer: Color(0xFF1A1A1A),
          outline: Color(0xFF333333),
          onSurfaceVariant: Color(0xFF999999),
          error: Color(0xFFCF6679),
          errorContainer: Color(0xFF442626),
          onErrorContainer: Color(0xFFCF6679),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1A1A),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Color(0xFF333333)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1A1A1A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.white, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.black,
          indicatorColor: Colors.white.withValues(alpha: 0.08),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF333333),
        ),
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
    CurrentPageState.instance.setFrameworkPage('auth_gate');
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.authNotifier,
      builder: (context, loggedIn, _) {
        if (loggedIn) {
          return const FilePickerPage();
        }
        return AuthPage(
          onAuthSuccess: () {},
        );
      },
    );
  }
}

// ============================================================
// 启动页：主页
// ============================================================

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

      // 弹出确认对话框：是否添加到"我的 APP"
      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('添加到我的 APP'),
          content: const Text('是否将此应用添加到"我的 APP"列表？\n\n添加后可以方便地复用和发布到市场。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('否'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('是'),
            ),
          ],
        ),
      );

      // 如果用户选择保存，则添加到"我的 APP"
      if (shouldSave == true) {
        try {
          await AppStorage.instance.save(config);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已添加到我的 APP')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('保存失败: $e')),
            );
          }
        }
      }

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
      debugPrint('[MyApp] 加载文件失败: $e');
    }
  }

  Future<void> _loadFromMarket(Map<String, dynamic> app) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final name = app['name'] as String;
      final version = app['version'] as String;
      
      // 使用 CacheManager 走统一的热更新缓存策略，传确切的版本号进行约束
      final config = await CacheManager.instance.getResource(
        name, 
        VersionConstraint.parse('^$version'), 
        type: 'app'
      );

      if (config == null) {
        throw Exception('无法解析或下载该应用配置');
      }

      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      await interpreter.executeSteps();

      _loadedFileName = name;
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

  Widget _buildEntryCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28, color: cs.onSurface),
              const SizedBox(height: 16),
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('home');
    final cs = Theme.of(context).colorScheme;
    final username = AuthService.currentUser?['username'] ??
        AuthService.currentUser?['email']?.toString().split('@').first ??
        '';

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top bar
              Row(
                children: [
                  Text(
                    'MyApp',
                    style: GoogleFonts.inter(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.settings_outlined, color: cs.onSurface),
                    onPressed: _openSettings,
                  ),
                  if (AuthService.isLoggedIn)
                    PopupMenuButton<String>(
                      icon: Icon(Icons.account_circle_outlined, color: cs.onSurface),
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
                            style: TextStyle(color: cs.onSurface),
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'profile',
                          child: Row(
                            children: [
                              Icon(Icons.person_outline, size: 18),
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

              const SizedBox(height: 36),

              // Welcome
              Text(
                'Hi, $username',
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '探索和运行你的应用',
                style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: 32),

              // Cards grid
              Row(
                children: [
                  Expanded(
                    child: _buildEntryCard(
                      icon: Icons.store_outlined,
                      title: '应用市场',
                      subtitle: '发现精彩应用',
                      onTap: _loading ? null : _openMarket,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildEntryCard(
                      icon: Icons.apps_outlined,
                      title: '我的 APP',
                      subtitle: '历史记录',
                      onTap: _loading ? null : _openMyApps,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Local file card
              Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _loading ? null : _pickAndLoadJson,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                    child: Row(
                      children: [
                        Icon(Icons.folder_open_outlined, size: 24, color: cs.onSurface),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '选择本地文件',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '从设备导入 JSON 配置',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_loading)
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.onSurface,
                            ),
                          )
                        else
                          Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),

              // Error
              if (_error != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: cs.error, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 48),

              // Version
              Center(
                child: Text(
                  'v1.1.0',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
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
      // 从 Registry 服务获取应用列表（只获取 type=app 的包）
      final resp = await http
          .get(Uri.parse('https://registry.dapangyu.work/packages?type=app'))
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        throw Exception('服务器错误 (${resp.statusCode})');
      }

      final data = json.decode(resp.body) as Map<String, dynamic>;
      final packages = (data['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      setState(() {
        _apps = packages;
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
    CurrentPageState.instance.setFrameworkPage('market');
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('应用市场', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchApps,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: cs.onSurface))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off, size: 48, color: cs.onSurfaceVariant),
                      const SizedBox(height: 16),
                      Text(_error!, style: TextStyle(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _fetchApps, child: const Text('重试')),
                    ],
                  ),
                )
              : _apps.isEmpty
                  ? Center(
                      child: Text('暂无可用应用',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _apps.length,
                      itemBuilder: (context, index) {
                        final app = _apps[index];
                        return _buildAppCard(context, app, cs);
                      },
                    ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String packageName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认下架'),
        content: Text('确定要永久删除包 "$packageName" 吗？\n\n此操作不可撤销，将删除所有版本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await _deletePackage(context, packageName);
    }
  }

  Future<void> _deletePackage(BuildContext context, String packageName) async {
    final cs = Theme.of(context).colorScheme;

    // 显示加载提示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: cs.onSurface),
                const SizedBox(height: 16),
                const Text('正在删除...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final token = AuthService.token;
      if (token == null) throw Exception('未登录');

      final resp = await http.delete(
        Uri.parse('https://registry.dapangyu.work/package/$packageName'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      if (context.mounted) Navigator.pop(context); // 关闭加载对话框

      if (resp.statusCode == 200) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('删除成功')),
          );
          // 刷新列表
          _fetchApps();
        }
      } else {
        final data = json.decode(resp.body);
        throw Exception(data['error'] ?? '删除失败');
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // 关闭加载对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  Widget _buildAppCard(BuildContext context, Map<String, dynamic> app,
      ColorScheme cs) {
    final name = app['name'] as String? ?? '';
    final desc = app['description'] as String? ?? '';
    final version = app['version']?.toString() ?? '';
    final author = app['author'] as String? ?? '';

    // 判断当前用户是否是管理员
    final isAdmin = AuthService.currentUser?['role'] == 'admin';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.of(context).pop();
          widget.onSelect(app);
        },
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
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                        if (version.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
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
                    if (desc.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        desc,
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
                        '作者: $author',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 如果是管理员，显示删除按钮
              if (isAdmin)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  color: Colors.red,
                  tooltip: '下架',
                  onPressed: () => _confirmDelete(context, name),
                ),
              Icon(Icons.download_outlined, color: cs.onSurfaceVariant),
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

bool _containsListInChildren(List<dynamic> children) {
  for (final child in children) {
    if (child is Map<String, dynamic>) {
      if (child['type'] == 'list') return true;
      final subChildren = child['children'] as List<dynamic>?;
      if (subChildren != null && _containsListInChildren(subChildren)) {
        return true;
      }
    }
  }
  return false;
}

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
      // 打印完整的错误堆栈到 debug 日志
      debugPrint('========================================');
      debugPrint('[JSON-APP] 运行时崩溃');
      debugPrint('文件: $fileName');
      debugPrint('错误: $e');
      debugPrint('========================================');
      debugPrint('完整堆栈:');
      debugPrint(stack.toString());
      debugPrint('========================================');

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
    CurrentPageState.instance.setJsonAppPage(
      screenId: currentScreenId,
      appName: interpreter.appName,
    );

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
    final hasListWidget = _containsListInChildren(children);

    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((childJson) => interpreter.buildWidget(context, childJson))
        .toList();

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
                child: buildScreenLayout(screenConfig, childWidgets),
              ),
      ),
    );
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
    CurrentPageState.instance.setFrameworkPage('crash');
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('运行出错', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
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
                    onPressed: () async {
                      final fullText = '$fileName 运行崩溃\n\n错误:\n$error\n\n堆栈:\n$stackTrace';
                      await Clipboard.setData(ClipboardData(text: fullText));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('崩溃信息已复制')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_all),
                    label: const Text('复制'),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      // 把崩溃信息发给 AI 分析（JSON 配置由 DesignerBall 自动注入上下文）
                      final crashMsg = 'JSON-APP 运行崩溃，请分析原因并输出修复后的完整 JSON：\n\n'
                          '## 错误\n$error\n\n'
                          '## 堆栈\n$stackTrace';
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
    final hasListWidget = _containsListInChildren(tabChildren);
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

  Future<void> _uploadToMarket(SavedApp app) async {
    if (_uploading) return;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PublishDialog(config: app.config),
    );

    if (result == true) {
      _showSnackBar('发布成功 🎉');
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('my_apps');
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('我的 APP', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
      ),
      body: _apps == null
          ? Center(child: CircularProgressIndicator(color: cs.onSurface))
          : _apps!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox_outlined, size: 64, color: cs.onSurfaceVariant),
                      const SizedBox(height: 16),
                      Text('还没有 APP', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('长按悬浮球，用语音让 AI 帮你生成', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
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
                              backgroundColor: cs.surfaceContainerHighest,
                              child: Icon(Icons.apps, color: cs.onSurface),
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
                                        size: 20, color: cs.onSurfaceVariant),
                                    tooltip: '上传到市场',
                                    onPressed: _uploading ? null : () => _uploadToMarket(app),
                                  ),
                                IconButton(
                                  icon: Icon(Icons.delete_outline, size: 20, color: cs.onSurfaceVariant),
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

// ============================================================
// 发布弹窗
// ============================================================

String _generateUuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final s = bytes.map(hex).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

bool _isValidUuid(String s) {
  return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(s);
}

class _PublishDialog extends StatefulWidget {
  final Map<String, dynamic> config;
  const _PublishDialog({required this.config});

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  final _registryUrl = 'https://registry.dapangyu.work';

  List<Map<String, dynamic>>? _namespaces;
  String? _selectedNamespace;
  bool _loadingNs = true;
  bool _publishing = false;
  String? _error;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _appidCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _versionCtrl;
  String _type = 'app';

  bool get _isAdmin => AuthService.currentUser?['role'] == 'admin';

  @override
  void initState() {
    super.initState();
    final meta = widget.config['meta'] as Map<String, dynamic>? ?? {};
    final rawAppid = widget.config['appid']?.toString() ?? '';

    _nameCtrl = TextEditingController(text: meta['name']?.toString() ?? '');
    _appidCtrl = TextEditingController(text: _isValidUuid(rawAppid) ? rawAppid : '');
    _descCtrl = TextEditingController(text: meta['description']?.toString() ?? '');
    _versionCtrl = TextEditingController(text: meta['version']?.toString() ?? '1.0.0');
    _type = meta['type']?.toString() ?? 'app';

    _fetchNamespaces();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _appidCtrl.dispose();
    _descCtrl.dispose();
    _versionCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchNamespaces() async {
    setState(() => _loadingNs = true);
    try {
      final resp = await http.get(
        Uri.parse('$_registryUrl/my-namespaces'),
        headers: {'Authorization': 'Bearer ${AuthService.token}'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final list = (data['namespaces'] as List<dynamic>)
            .map((e) => e as Map<String, dynamic>)
            .toList();
        if (mounted) {
          setState(() {
            _namespaces = list;
            _loadingNs = false;
            if (list.isNotEmpty && _selectedNamespace == null) {
              _selectedNamespace = list.first['name'] as String;
            }
          });
        }
      } else {
        if (mounted) setState(() => _loadingNs = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingNs = false);
    }
  }

  Future<void> _createNamespace() async {
    final ctrl = TextEditingController();
    final nsName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建命名空间'),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: '空间名称',
            hintText: '小写字母、数字、- 和 _',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (nsName == null || nsName.isEmpty) return;

    try {
      final resp = await http.post(
        Uri.parse('$_registryUrl/namespace/create'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AuthService.token}',
        },
        body: json.encode({'namespace': nsName}),
      ).timeout(const Duration(seconds: 10));

      final data = json.decode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200) {
        await _fetchNamespaces();
        if (mounted) setState(() => _selectedNamespace = nsName);
      } else {
        if (mounted) setState(() => _error = data['error']?.toString() ?? '创建失败');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '网络错误: $e');
    }
  }

  Future<void> _inviteMember() async {
    // 显示"开发中"提示
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('邀请成员'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction, size: 48, color: Colors.orange),
            SizedBox(height: 16),
            Text(
              '此功能正在开发中',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            SizedBox(height: 8),
            Text(
              '敬请期待！',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _doPublish() async {
    // 前端校验
    final name = _nameCtrl.text.trim();
    final appid = _appidCtrl.text.trim();
    final version = _versionCtrl.text.trim();
    final desc = _descCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _error = '包名不能为空');
      return;
    }
    if (!_isValidUuid(appid)) {
      setState(() => _error = 'AppID 必须是有效的 UUID 格式');
      return;
    }
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      setState(() => _error = '版本号必须是 x.y.z 格式');
      return;
    }
    if (!_isAdmin && (_selectedNamespace == null || _selectedNamespace!.isEmpty)) {
      setState(() => _error = '请选择命名空间或创建一个新空间');
      return;
    }

    setState(() {
      _publishing = true;
      _error = null;
    });

    try {
      final resp = await http.post(
        Uri.parse('$_registryUrl/publish'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AuthService.token}',
        },
        body: json.encode({
          'json_content': widget.config,
          'namespace': _isAdmin && (_selectedNamespace == null || _selectedNamespace == '_official_')
              ? ''
              : _selectedNamespace ?? '',
          'name': name,
          'appid': appid,
          'version': version,
          'description': desc,
          'type': _type,
        }),
      ).timeout(const Duration(seconds: 30));

      final data = json.decode(resp.body) as Map<String, dynamic>;

      if (resp.statusCode == 200) {
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      // UUID 冲突
      if (resp.statusCode == 409 && data['uuid_conflict'] == true) {
        final pkg = data['conflicting_package']?.toString() ?? '';
        if (mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('UUID 冲突'),
              content: Text('该 UUID 已被包 "$pkg" 使用。\n请点击「随机生成 🎲」获取新的 UUID 后重试。'),
              actions: [
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
              ],
            ),
          );
          setState(() => _publishing = false);
        }
        return;
      }

      // 其他错误
      if (mounted) {
        setState(() {
          _error = data['error']?.toString() ?? '发布失败 (${resp.statusCode})';
          _publishing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '网络错误: $e';
          _publishing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('发布到市场')),
          TextButton.icon(
            onPressed: _inviteMember,
            icon: const Icon(Icons.person_add, size: 18),
            label: const Text('邀请成员'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _createNamespace,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('创建空间'),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!, style: TextStyle(color: cs.onErrorContainer, fontSize: 13)),
                ),
                const SizedBox(height: 12),
              ],

              // 命名空间 + 名字（一行两列）
              Row(
                children: [
                  // 命名空间选择器
                  Expanded(
                    child: _loadingNs
                        ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : DropdownButtonFormField<String>(
                            value: _selectedNamespace,
                            decoration: InputDecoration(
                              labelText: '项目空间',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                            ),
                            isExpanded: true,
                            items: [
                              if (_isAdmin)
                                const DropdownMenuItem(
                                  value: '_official_',
                                  child: Text('(官方/无空间)', style: TextStyle(fontStyle: FontStyle.italic)),
                                ),
                              ...(_namespaces ?? []).map((ns) {
                                final n = ns['name'] as String;
                                return DropdownMenuItem(value: n, child: Text(n));
                              }),
                            ],
                            onChanged: (v) => setState(() => _selectedNamespace = v),
                          ),
                  ),
                  const SizedBox(width: 12),
                  // 包名
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      decoration: InputDecoration(
                        labelText: '包名',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // AppID + 随机生成按钮
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _appidCtrl,
                      decoration: InputDecoration(
                        labelText: 'AppID (UUID)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      ),
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() => _appidCtrl.text = _generateUuidV4());
                    },
                    icon: const Icon(Icons.casino, size: 18),
                    label: const Text('随机生成'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 描述
              TextField(
                controller: _descCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '描述',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                ),
              ),
              const SizedBox(height: 14),

              // 版本号 + 类型（一行两列）
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _versionCtrl,
                      decoration: InputDecoration(
                        labelText: '版本号',
                        hintText: '1.0.0',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _type,
                      decoration: InputDecoration(
                        labelText: '类型',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'app', child: Text('App')),
                        DropdownMenuItem(value: 'library', child: Text('Library')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _type = v);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _publishing ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _publishing ? null : _doPublish,
          child: _publishing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('发布'),
        ),
      ],
    );
  }
}
