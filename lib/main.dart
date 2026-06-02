import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:firebase_core/firebase_core.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'config/app_config.dart';
import 'config/environment_service.dart';
import 'config/remote_config_service.dart';
import 'i18n/framework_strings.dart';
import 'i18n/locale_controller.dart';
import 'i18n/language_switcher.dart';
import 'i18n/meta_helper.dart';
import 'theme/theme_controller.dart';
import 'platform/native_fs.dart';
import 'json_ui/interpreter.dart';
import 'json_ui/cache_manager.dart';
import 'json_ui/semver.dart';
import 'json_ui/widgets/screen_layout.dart';
import 'json_ui/widgets/icon_registry.dart';
import 'json_ui/widgets/app_bar_widget.dart' as appbar_helper;
import 'json_ui/widgets/drawer_helper.dart' as drawer_helper;
import 'designer/designer_ball.dart';
import 'designer/market_detail_page.dart';
import 'designer/market_favorites.dart';
import 'designer/settings_page.dart';
import 'designer/ai_chat_service.dart';
import 'designer/app_storage.dart';
import 'designer/default_startup_prefs.dart';
import 'auth/auth_service.dart';
import 'auth/auth_page.dart';
import 'im/im_conversation_entry.dart';
import 'im/im_service.dart';
import 'navigation/app_route_observer.dart';
import 'onboarding/onboarding_keys.dart';
import 'onboarding/onboarding_service.dart';

// ============================================================
// Riverpod Providers
// ============================================================

/// JSON 解释器的全局 Provider
final interpreterProvider = ChangeNotifierProvider<JsonInterpreter>((ref) {
  return JsonInterpreter();
});

/// 全局 App 生命周期事件总线（resume / pause / inactive / detached / hidden）。
/// JSON-APP 在 global.lifecycle.onResume 等字段声明步骤，
/// 解释器订阅这个 notifier 调度对应回调。
final ValueNotifier<String> appLifecycleEvent = ValueNotifier<String>('init');

/// app 进程启动时刻。splash 用它算"已经过去多久"，决定还要不要再展示一会儿
/// （达到 RemoteConfigService.splashDuration 才放行）。
final DateTime appStartTime = DateTime.now();

const List<String> _localJsonDebugParamNames = [
  'local_json',
  'json_path',
  'json_app',
];

String? _localJsonDebugSource() {
  final params = Uri.base.queryParameters;
  for (final name in _localJsonDebugParamNames) {
    final value = params[name]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

bool _isLocalDebugHost() {
  if (!kIsWeb) return true;
  final host = Uri.base.host.toLowerCase();
  return host.isEmpty ||
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';
}

String? _lastUiCrashKey;
DateTime? _lastUiCrashAt;

void _routeJsonUiCrash(FlutterErrorDetails details) {
  final page = CurrentPageState.instance;
  if (!page.isInJsonApp) return;
  if (page.frameworkPage == 'crash') return;

  final error = details.exception.toString();
  final stack = details.stack?.toString() ?? '';
  final appName = page.jsonAppName ?? 'JSON App';
  final key = '$appName|$error|${stack.split('\n').take(3).join('|')}';
  final now = DateTime.now();
  if (_lastUiCrashKey == key &&
      _lastUiCrashAt != null &&
      now.difference(_lastUiCrashAt!) < const Duration(seconds: 2)) {
    return;
  }
  _lastUiCrashKey = key;
  _lastUiCrashAt = now;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    final navState = JsonDslApp.navigatorKey.currentState;
    if (navState == null || !navState.mounted) {
      debugPrint('[JSON-APP] UI crash before nav ready: $error\n$stack');
      return;
    }
    if (CurrentPageState.instance.frameworkPage == 'crash') return;
    debugPrint('========================================');
    debugPrint('[JSON-APP] UI 渲染/布局崩溃');
    debugPrint('应用: $appName');
    debugPrint('错误: $error');
    debugPrint('========================================');
    debugPrint(stack);
    debugPrint('========================================');
    navState.push(
      MaterialPageRoute(
        builder: (_) =>
            _CrashPage(error: error, stackTrace: stack, fileName: appName),
      ),
    );
  });
}

void _sendUiCrashToAi(FlutterErrorDetails details) {
  final page = CurrentPageState.instance;
  final appName = page.jsonAppName ?? 'JSON App';
  final stack = details.stack?.toString() ?? '';
  final crashMsg =
      'JSON-APP UI 渲染/布局崩溃，请分析原因并输出修复后的完整 JSON：\n\n'
      '## 应用\n$appName\n\n'
      '## 错误\n${details.exception}\n\n'
      '## 堆栈\n$stack';
  DesignerBall.sendCrashReport?.call(crashMsg);
}

class _InlineRenderCrashWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  final bool compact;

  const _InlineRenderCrashWidget({
    required this.details,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.lookup(
      appLocale.value ??
          Localizations.maybeLocaleOf(context) ??
          const Locale('zh', 'CN'),
    );
    final maxWidth = compact ? 220.0 : 360.0;
    final maxHeight = compact ? 64.0 : 220.0;

    return Align(
      alignment: Alignment.topLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.all(4),
            padding: EdgeInsets.all(compact ? 8 : 12),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: compact
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          t.uiRenderCrash,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.red,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                t.uiRenderCrash,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          details.exception.toString(),
                          maxLines: 4,
                          overflow: TextOverflow.fade,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: CurrentPageState.instance.isInJsonApp
                                ? () => _sendUiCrashToAi(details)
                                : null,
                            icon: const Icon(Icons.auto_fix_high, size: 16),
                            label: Text(t.crashAiFix),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        appLifecycleEvent.value = 'resume';
        break;
      case AppLifecycleState.paused:
        appLifecycleEvent.value = 'pause';
        break;
      case AppLifecycleState.inactive:
        appLifecycleEvent.value = 'inactive';
        break;
      case AppLifecycleState.detached:
        appLifecycleEvent.value = 'detached';
        break;
      case AppLifecycleState.hidden:
        appLifecycleEvent.value = 'hidden';
        break;
    }
  }
}

// ============================================================
// 入口
// ============================================================

void main() async {
  // 触发 appStartTime 的 lazy init 到尽可能早。这个时间点决定 splash 至少要
  // 展示到 t + RemoteConfigService.splashDuration 才能被 dismiss。
  appStartTime;

  WidgetsFlutterBinding.ensureInitialized();
  final localJsonDebug = _localJsonDebugSource() != null && _isLocalDebugHost();

  // Firebase Core 初始化 —— FirebaseMessaging 等所有 firebase_xxx 插件都依赖它。
  // Android 自动从 android/app/google-services.json 读配置；其他平台暂时不开 FCM 跳过。
  // 失败吞掉：FCM 不可用不应阻塞 app 启动（iOS 走 APNs 也用不上 Firebase）
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await Firebase.initializeApp();
    } catch (e) {
      // ignore: avoid_print
      print('[main] Firebase.initializeApp 失败 (FCM 推送不可用): $e');
    }
  }

  // 加载服务环境配置 —— 必须在任何 HTTP 请求之前，否则会用错地址。
  // 失败 fail-open 回退到生产，绝不阻塞启动。
  await EnvironmentService.instance.load();

  // 加载用户语言偏好（SharedPreferences app_locale；未设置则跟随系统）
  await LocaleController.loadFromPrefs();

  // 加载用户主题偏好（SharedPreferences app_theme_mode；未设置则跟随系统）
  await ThemeController.loadFromPrefs();

  // 注册 app 生命周期监听（resume / pause / inactive / detached / hidden）
  WidgetsBinding.instance.addObserver(_AppLifecycleObserver());

  // app 切回前台时刷新 remote config（带 ETag，命中 304 几乎零开销）
  appLifecycleEvent.addListener(() {
    if (appLifecycleEvent.value == 'resume') {
      // ignore: unawaited_futures
      RemoteConfigService.instance.refreshIfStale();
    }
  });

  // 捕捉全局渲染和布局异常（防止布局越界等导致直接白屏）
  ErrorWidget.builder = (FlutterErrorDetails details) {
    _routeJsonUiCrash(details);
    return _InlineRenderCrashWidget(
      details: details,
      compact: CurrentPageState.instance.isInJsonApp,
    );
  };

  // JSON-DSL 动作执行类异常（按钮 onPressed / @start steps / @if 求值等）
  // 兜底：路由到 _CrashPage（含 AI 一键修复按钮）。这条路径专门覆盖
  // JsonScreenView.build 同步沙盒抓不到的 async 异常。
  JsonInterpreter.onActionCrash = (error, stack, fileName) {
    final navState = JsonDslApp.navigatorKey.currentState;
    if (navState == null) {
      debugPrint('[JSON-APP] action crash before nav ready: $error\n$stack');
      return;
    }
    debugPrint('========================================');
    debugPrint('[JSON-APP] 运行时崩溃 (action/steps)');
    debugPrint('文件: $fileName');
    debugPrint('错误: $error');
    debugPrint('========================================');
    debugPrint(stack.toString());
    debugPrint('========================================');
    navState.push(
      MaterialPageRoute(
        builder: (_) => _CrashPage(
          error: error.toString(),
          stackTrace: stack.toString(),
          fileName: fileName,
        ),
      ),
    );
  };

  // 并行：恢复鉴权 + 拉取远程配置（1s 超时，超时 fall back 到缓存/默认值）。
  // 配置必须早于 splash 渲染拿到，splash_text / splash_duration_ms 才能正确生效。
  await Future.wait([
    if (!localJsonDebug) AuthService.restoreSession(),
    AiChatService.loadProvider(),
    if (!localJsonDebug) RemoteConfigService.instance.bootstrap(),
  ]);
  // 如果已登录，后台初始化 IM 连接
  if (!localJsonDebug && AuthService.isLoggedIn) {
    IMService.instance.restoreSession();
  }
  runApp(const ProviderScope(child: JsonDslApp()));
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
    return ValueListenableBuilder<Locale?>(
      valueListenable: appLocale,
      builder: (context, locale, _) => ValueListenableBuilder<ThemeMode>(
        valueListenable: appThemeMode,
        builder: (context, mode, _) => _buildApp(context, ref, mode, locale),
      ),
    );
  }

  Widget _buildApp(
    BuildContext context,
    WidgetRef ref,
    ThemeMode mode,
    Locale? locale,
  ) {
    return MaterialApp(
      title: 'MyApp',
      navigatorKey: navigatorKey,
      navigatorObservers: [appRouteObserver],
      debugShowCheckedModeBanner: false,
      locale: locale, // null = 跟随系统
      supportedLocales: T.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (deviceLocale, supported) {
        // 用户没显式选 locale 时，按系统 locale 匹配；不在支持列表里就回退中文
        if (locale != null) return locale;
        if (deviceLocale != null) {
          for (final s in supported) {
            if (s.languageCode == deviceLocale.languageCode) return s;
          }
        }
        return T.supportedLocales.first;
      },
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
          style: TextButton.styleFrom(foregroundColor: Colors.black),
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
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Colors.black.withValues(alpha: 0.08),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFFE0E0E0)),
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
          style: TextButton.styleFrom(foregroundColor: Colors.white),
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
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.black,
          indicatorColor: Colors.white.withValues(alpha: 0.08),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFF333333)),
      ),
      themeMode: mode,
      // 使用 builder 注入悬浮球，凌驾于所有路由之上
      builder: (context, child) {
        if (_localJsonDebugSource() != null && _isLocalDebugHost()) {
          return child ?? const SizedBox.shrink();
        }
        return DesignerBall(
          child: child ?? const SizedBox.shrink(),
          getCurrentConfig: () => ProviderScope.containerOf(
            context,
          ).read(interpreterProvider).rawConfig,
          onRunJsonApp: (jsonConfig) async {
            final interpreter = ProviderScope.containerOf(
              context,
            ).read(interpreterProvider);
            try {
              // 保存到本地
              await AppStorage.instance.save(
                Map<String, dynamic>.from(jsonConfig),
              );
              interpreter.loadConfig(jsonConfig);
              await interpreter.executeSteps();
              final meta = jsonConfig['meta'] as Map<String, dynamic>? ?? {};
              final name = resolveDisplayName(meta, fallback: 'AI 生成');
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
      home:
          _LocalJsonDebugLoader.maybeBuild() ??
          const _SplashGate(child: _AuthGate()),
    );
  }
}

class _LocalJsonDebugLoader extends ConsumerStatefulWidget {
  final String source;

  const _LocalJsonDebugLoader({required this.source});

  static Widget? maybeBuild() {
    final source = _localJsonDebugSource();
    if (source == null || !_isLocalDebugHost()) return null;
    return _LocalJsonDebugLoader(source: source);
  }

  @override
  ConsumerState<_LocalJsonDebugLoader> createState() =>
      _LocalJsonDebugLoaderState();
}

class _LocalJsonDebugLoaderState extends ConsumerState<_LocalJsonDebugLoader> {
  bool _loading = true;
  String? _error;
  String? _fileName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _readJsonSource(String source) async {
    final uri = Uri.tryParse(source);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}: $source');
      }
      return resp.body;
    }

    if (kIsWeb) {
      final helper = Uri.parse(
        Uri.base.queryParameters['local_json_server'] ??
            'http://127.0.0.1:8765/json',
      );
      final query = Map<String, String>.from(helper.queryParameters)
        ..['path'] = source;
      final resp = await http
          .get(helper.replace(queryParameters: query))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw Exception('Local JSON helper ${resp.statusCode}: ${resp.body}');
      }
      return resp.body;
    }

    final content = await NativeFs.readStringAbs(source);
    if (content == null) {
      throw Exception('File not found or unreadable: $source');
    }
    return content;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final jsonStr = await _readJsonSource(widget.source);
      final config = json.decode(jsonStr) as Map<String, dynamic>;
      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      await interpreter.executeSteps();
      final meta = config['meta'] as Map<String, dynamic>?;
      final fallback = widget.source.split('/').last;
      final fileName = resolveDisplayName(meta, fallback: fallback);
      if (!mounted) return;
      setState(() {
        _fileName = fileName;
        _loading = false;
      });
    } catch (e, stack) {
      debugPrint('[LocalJsonDebug] load failed: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('local_json_debug');
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      final cs = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(title: const Text('Local JSON Debug')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Failed to load local JSON',
                  style: TextStyle(
                    color: cs.error,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(widget.source),
                const SizedBox(height: 12),
                SelectableText(_error!, style: TextStyle(color: cs.error)),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return JsonScreenView(
      fileName: _fileName ?? 'Local JSON',
      isStartupRoot: true,
    );
  }
}

/// 启动 splash —— 兼顾 "至少展示 splash_duration_ms" 与 "至多展示到 RemoteConfig
/// 配置的时长"。展示期间显示 splash_text（如 "Welcome"）。
///
/// 时序：
///   appStartTime ─────────────────────────────► splash_dismissed
///                       max(elapsed, splash_duration_ms)
///
/// - 慢机器：bootstrap 已花掉 splash_duration_ms，splash 立刻消失
/// - 快机器：bootstrap 很快，splash 撑到 splash_duration_ms 才消失
class _SplashGate extends StatefulWidget {
  final Widget child;
  const _SplashGate({required this.child});

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _showSplash = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleDismiss();
  }

  void _scheduleDismiss() {
    final elapsed = DateTime.now().difference(appStartTime);
    final required = RemoteConfigService.instance.splashDuration;
    final remaining = required - elapsed;
    if (remaining <= Duration.zero) {
      _showSplash = false;
      return;
    }
    _timer = Timer(remaining, () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_awesome, size: 56, color: cs.onSurface),
              const SizedBox(height: 18),
              Text(
                'MyApp',
                style: GoogleFonts.inter(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              // splash_text 实时跟着 RemoteConfigService 走（admin 改了 → resume
              // 时 refetch → notifyListeners → 这里跟着重建）
              AnimatedBuilder(
                animation: RemoteConfigService.instance,
                builder: (_, __) {
                  final txt = RemoteConfigService.instance.splashText;
                  if (txt.isEmpty) return const SizedBox.shrink();
                  return Text(
                    txt,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, color: cs.onSurfaceVariant),
                  );
                },
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
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
          IMService.instance.login();
          return const FilePickerPage();
        }
        return AuthPage(onAuthSuccess: () {});
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

  /// 启动期占位：等读 SharedPreferences + 看有没有默认启动 App。
  /// 有的话直接 pushReplacement 走，不让 home 闪一下；没的话 setState 改成
  /// false 进入正常 home UI。
  bool _bootstrapping = !_FilePickerPageState._autoStartupConsumed;

  // FilePickerPage 已经被 push 过一次默认启动 App 了（同一进程内）；
  // 避免每次 popUntil 回到 home 时又自动跳走，让"回到主页"真的能停住
  static bool _autoStartupConsumed = false;

  @override
  void initState() {
    super.initState();
    // 第一次到主页 → 触发新手引导。等两帧让目标 widget 全部 mount + layout 完成
    // （DesignerBall 在 MaterialApp.builder 里更晚 layout）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        OnboardingService.maybeStart(context);
      });
    });
    // 默认启动 App：冷启动时（未消费过）按用户设置直接 push 进选中应用
    if (!_autoStartupConsumed) {
      _autoStartupConsumed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeAutoLoadDefaultStartup();
      });
    }
  }

  Future<void> _maybeAutoLoadDefaultStartup() async {
    final cfg = await DefaultStartupPrefs.read();
    if (!mounted) return;
    if (!cfg.hasTarget) {
      // 没设默认启动 App → 退出占位、渲染正常 home
      setState(() => _bootstrapping = false);
      return;
    }
    // 注意：成功 push JsonScreenView 后保持 _bootstrapping=true，等用户从
    // JSON-APP pop 回来时由 Navigator.push().whenComplete 翻成 false。
    // 这里要是 finally 里立刻翻 false，FilePickerPage 会赶在 push 转场动画
    // 期间 rebuild 出 home，从底下露出来"闪一下"。
    switch (cfg.kind) {
      case DefaultStartupKind.market:
        if (cfg.marketName != null && cfg.marketVersion != null) {
          await _loadFromMarket({
            'name': cfg.marketName,
            'version': cfg.marketVersion,
          }, isStartupRoot: true);
          return;
        }
      case DefaultStartupKind.local:
        if (cfg.localFileName != null) {
          final apps = await AppStorage.instance.list();
          final app = apps.firstWhere(
            (a) => a.fileName == cfg.localFileName,
            orElse: () => SavedApp(
              fileName: '',
              name: '',
              description: '',
              savedAt: '',
              config: const {},
            ),
          );
          if (app.fileName.isNotEmpty) {
            await _loadSavedApp(app, isStartupRoot: true);
            return;
          }
        }
      case DefaultStartupKind.none:
        break;
    }
    // 走到这里：配的目标已经不存在（market 字段缺失 / 本地 app 被删）→ 退出占位
    if (mounted) {
      setState(() => _bootstrapping = false);
    }
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
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
        withData: true, // web 没有文件路径，必须靠 bytes 拿内容
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      // web：用 bytes；移动/桌面：bytes 通常也有（withData），否则回退读路径
      final picked = result.files.single;
      String? jsonStr;
      if (picked.bytes != null) {
        jsonStr = utf8.decode(picked.bytes!);
      } else if (picked.path != null) {
        jsonStr = await NativeFs.readStringAbs(picked.path!);
      }
      if (jsonStr == null) {
        setState(() {
          _loading = false;
          _error = T.of(context).errorPathUnavailable;
        });
        return;
      }

      final config = json.decode(jsonStr) as Map<String, dynamic>;

      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      await interpreter.executeSteps();

      _loadedFileName = result.files.single.name;

      setState(() => _loading = false);

      if (!mounted) return;

      // 弹出确认对话框：是否添加到"我的 APP"
      final t = T.of(context);
      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) {
          final dt = T.of(dialogCtx);
          return AlertDialog(
            title: Text(dt.addToMyAppsTitle),
            content: Text(dt.addToMyAppsContent),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: Text(dt.no),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: Text(dt.yes),
              ),
            ],
          );
        },
      );

      // 如果用户选择保存，则添加到"我的 APP"
      if (shouldSave == true) {
        try {
          await AppStorage.instance.save(config);
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(t.addToMyAppsAdded)));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(T.fmt(t.saveFailedWith, {'msg': '$e'}))),
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

  Future<void> _loadFromMarket(
    Map<String, dynamic> app, {
    bool isStartupRoot = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final name = app['name']?.toString() ?? '';
      final version = app['version']?.toString().trim() ?? '';
      if (name.isEmpty) {
        throw Exception(T.current.mainCantResolveAppConfigError);
      }

      // 市场详情页选择的是要运行的具体版本；这里必须精确解析，避免
      // "^1.5.1 + preferLatest" 把旧版本又升级成最新版，导致版本对比失真。
      final config = await CacheManager.instance.getResource(
        name,
        VersionConstraint.parse(version.isEmpty ? '*' : version),
        type: 'app',
        preferLatest: version.isEmpty,
      );

      if (config == null) {
        throw Exception(T.current.mainCantResolveAppConfigError);
      }

      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      await interpreter.executeSteps();

      // 用 displayName（多语言）作为 fileName 标题；优先 config.meta，再回退到 app dict
      final configMeta = config['meta'] as Map<String, dynamic>?;
      _loadedFileName = resolveDisplayName(
        configMeta ?? {'name': name},
        fallback: name,
      );
      setState(() => _loading = false);

      if (!mounted) return;

      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => JsonScreenView(
                fileName: _loadedFileName!,
                isStartupRoot: isStartupRoot,
              ),
            ),
          )
          .whenComplete(() {
            // startup root：等用户从 JSON-APP pop 回来才退出占位，让 home 显示。
            // 之前在 push 之前就翻 false，转场动画期间 home 会从底下被瞄到 → 闪一下。
            if (isStartupRoot && mounted) {
              setState(() => _bootstrapping = false);
            }
          });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
        // 加载失败也得退占位，否则用户卡在 spinner 看不到错误
        if (isStartupRoot) _bootstrapping = false;
      });
    }
  }

  void _openMarket() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _MarketPage(onSelect: _loadFromMarket)),
    );
  }

  void _openMyApps() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _MyAppsPage(onSelect: _loadSavedApp)),
    );
  }

  Future<void> _loadSavedApp(SavedApp app, {bool isStartupRoot = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(app.config);
      await interpreter.executeSteps();
      final meta = app.config['meta'] as Map<String, dynamic>?;
      final displayName = resolveDisplayName(meta, fallback: app.name);
      _loadedFileName = displayName;
      setState(() => _loading = false);
      if (!mounted) return;
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => JsonScreenView(
                fileName: displayName,
                isStartupRoot: isStartupRoot,
              ),
            ),
          )
          .whenComplete(() {
            // 同 _loadFromMarket：等 pop 回来才退占位，避免转场闪 home
            if (isStartupRoot && mounted) {
              setState(() => _bootstrapping = false);
            }
          });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
        if (isStartupRoot) _bootstrapping = false;
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
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 启动期：只渲染极简占位，不让 home 在用户面前闪一下
    // （等 _maybeAutoLoadDefaultStartup 决定是 push 进 JSON-APP 还是
    //  setState(_bootstrapping=false) 切回正常 home）
    if (_bootstrapping) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    CurrentPageState.instance.setFrameworkPage('home');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);
    final username =
        AuthService.currentUser?['username'] ??
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
                    t.homeAppTitle,
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
                      key: OnboardingKeys.userMenu,
                      icon: Icon(
                        Icons.account_circle_outlined,
                        color: cs.onSurface,
                      ),
                      onSelected: (value) async {
                        if (value == 'profile') {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ProfilePage(),
                            ),
                          );
                        } else if (value == 'language') {
                          await showLanguagePicker(context);
                        } else if (value == 'replay_onboarding') {
                          // 等下一帧 PopupMenu 收起，目标 widget 才能被 hit-test
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            OnboardingService.forceStart(context);
                          });
                        } else if (value == 'logout') {
                          await IMService.instance.logout();
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
                        PopupMenuItem(
                          value: 'profile',
                          child: Row(
                            children: [
                              const Icon(Icons.person_outline, size: 18),
                              const SizedBox(width: 8),
                              Text(t.userMenuProfile),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'language',
                          child: Row(
                            children: [
                              const Icon(Icons.language, size: 18),
                              const SizedBox(width: 8),
                              Text(t.settingsLanguage),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'replay_onboarding',
                          child: Row(
                            children: [
                              const Icon(Icons.help_outline, size: 18),
                              const SizedBox(width: 8),
                              Text(t.onboardingReplayMenu),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'logout',
                          child: Row(
                            children: [
                              const Icon(Icons.logout, size: 18),
                              const SizedBox(width: 8),
                              Text(t.userMenuLogout),
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
                T.fmt(t.homeWelcome, {'name': username}),
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                t.homeSubtitle,
                style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant),
              ),

              const SizedBox(height: 32),

              // Cards grid
              Row(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: OnboardingKeys.marketCard,
                      child: _buildEntryCard(
                        icon: Icons.store_outlined,
                        title: t.homeMarket,
                        subtitle: t.homeMarketSubtitle,
                        onTap: _loading ? null : _openMarket,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: KeyedSubtree(
                      key: OnboardingKeys.myAppsCard,
                      child: _buildEntryCard(
                        icon: Icons.apps_outlined,
                        title: t.homeMyApps,
                        subtitle: t.homeMyAppsSubtitle,
                        onTap: _loading ? null : _openMyApps,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 消息（IM）入口 — 带未读数角标
              ValueListenableBuilder<int>(
                valueListenable: IMService.instance.unreadCountNotifier,
                builder: (context, unread, _) {
                  return Card(
                    key: OnboardingKeys.messagesCard,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () async {
                        // 捕获 across-async 用到的对象，避免 use_build_context_synchronously
                        final messenger = ScaffoldMessenger.of(context);
                        final navigator = Navigator.of(context);
                        if (!IMService.isPlatformSupported) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'IM 仅支持 iOS / Android（OpenIM SDK 限制）。请在 iOS 模拟器或真机上运行。',
                              ),
                              duration: Duration(seconds: 3),
                            ),
                          );
                          return;
                        }
                        if (!IMService.instance.isLoggedIn) {
                          final ok = await IMService.instance.login();
                          if (!mounted) return;
                          if (!ok) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(T.of(context).homeImLoginFailed),
                              ),
                            );
                            return;
                          }
                        }
                        if (!mounted) return;
                        navigator.push(
                          MaterialPageRoute(
                            builder: (_) => const IMConversationPage(),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 18,
                        ),
                        child: Row(
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  Icons.chat_outlined,
                                  size: 24,
                                  color: cs.onSurface,
                                ),
                                if (unread > 0)
                                  Positioned(
                                    right: -6,
                                    top: -4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: cs.error,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 16,
                                        minHeight: 16,
                                      ),
                                      child: Text(
                                        unread > 99 ? '99+' : unread.toString(),
                                        style: TextStyle(
                                          color: cs.onError,
                                          fontSize: 10,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    T.of(context).homeMessages,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    unread > 0
                                        ? T.fmt(T.of(context).homeUnreadCount, {
                                            'n': unread,
                                          })
                                        : T.of(context).homeMessagesSubtitle,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: cs.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 12),

              // Local file card
              Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _loading ? null : _pickAndLoadJson,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.folder_open_outlined,
                          size: 24,
                          color: cs.onSurface,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.homePickFile,
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                t.homePickFileSubtitle,
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
                          style: TextStyle(
                            color: cs.onErrorContainer,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 48),

              // Version
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'v${AppConfig.appVersion}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (AppConfig.gitCommit.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        AppConfig.gitCommit,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ],
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
  static const int _pageSize = 20;

  List<Map<String, dynamic>> _apps = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;
  int _selectedTabIndex = 0; // 0: App, 1: Library
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _fetchApps();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchApps({bool reset = true}) async {
    // ⚠️ 不能用 T.of(context) —— initState 第一次调 _fetchApps 时
    // InheritedWidget 还没挂上，dependOnInheritedWidgetOfExactType 会同步抛，
    // 且 throw 发生在 try 之前 → catch 接不到 → _loading 永远 true。
    // 用 T.current 走 LocaleController，不依赖 context。
    if (!reset && (_loadingMore || !_hasMore || _loading)) return;
    if (mounted) {
      setState(() {
        if (reset) {
          _loading = true;
          _page = 1;
          _hasMore = false;
        } else {
          _loadingMore = true;
        }
        _error = null;
      });
    }

    try {
      // 收藏 tab：从本地 SharedPreferences 读，不打 registry
      if (_selectedTabIndex == 2) {
        final favs = await MarketFavorites.list();
        final query = _searchController.text.trim().toLowerCase();
        if (!mounted) return;
        setState(() {
          _apps = favs
              .map(
                (e) => <String, dynamic>{
                  'name': e['name'],
                  'display_name': e['display_name'],
                },
              )
              .where((e) {
                if (query.isEmpty) return true;
                return (e['name']?.toString().toLowerCase() ?? '').contains(
                      query,
                    ) ||
                    (e['display_name']?.toString().toLowerCase() ?? '')
                        .contains(query);
              })
              .toList();
          _loading = false;
        });
        return;
      }

      final type = _selectedTabIndex == 0 ? 'app' : 'library';
      final nextPage = reset ? 1 : _page + 1;
      final query = _searchController.text.trim();
      final uri = Uri.parse('${AppConfig.registryUrl}/packages').replace(
        queryParameters: {
          'type': type,
          'page': nextPage.toString(),
          'per_page': _pageSize.toString(),
          if (query.isNotEmpty) 'q': query,
        },
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        throw Exception(
          T.fmt(T.current.errorServerWithCode, {'code': resp.statusCode}),
        );
      }

      final data = json.decode(resp.body) as Map<String, dynamic>;
      final packages = (data['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      if (!mounted) return;
      setState(() {
        _apps = reset ? packages : [..._apps, ...packages];
        _loading = false;
        _loadingMore = false;
        _page = nextPage;
        _hasMore = data['has_more'] == true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted && _selectedTabIndex != 2) {
        _fetchApps();
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  void _onTabChanged(int index) {
    if (_selectedTabIndex != index) {
      setState(() {
        _selectedTabIndex = index;
      });
      _fetchApps();
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('market');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          t.marketTitle,
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchApps),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: cs.surface,
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _onTabChanged(0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _selectedTabIndex == 0
                                ? cs.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        'App',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: _selectedTabIndex == 0
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: _selectedTabIndex == 0
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => _onTabChanged(1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _selectedTabIndex == 1
                                ? cs.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        'Library',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: _selectedTabIndex == 1
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: _selectedTabIndex == 1
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => _onTabChanged(2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _selectedTabIndex == 2
                                ? cs.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        Localizations.localeOf(
                              context,
                            ).languageCode.startsWith('zh')
                            ? '收藏'
                            : 'Favorites',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: _selectedTabIndex == 2
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: _selectedTabIndex == 2
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _fetchApps(),
              decoration: InputDecoration(
                hintText: t.marketSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _fetchApps();
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          Expanded(child: _buildMarketBody(context, cs, t)),
        ],
      ),
    );
  }

  Widget _buildMarketBody(
    BuildContext context,
    ColorScheme cs,
    FrameworkStrings t,
  ) {
    return _loading
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
                FilledButton(onPressed: _fetchApps, child: Text(t.retry)),
              ],
            ),
          )
        : _apps.isEmpty
        ? Center(
            child: Text(
              t.marketEmpty,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _apps.length + (_hasMore || _loadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _apps.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: _loadingMore
                        ? const CircularProgressIndicator()
                        : OutlinedButton(
                            onPressed: () => _fetchApps(reset: false),
                            child: Text(t.marketLoadMore),
                          ),
                  ),
                );
              }
              final app = _apps[index];
              return _buildAppCard(context, app, cs);
            },
          );
  }

  Future<void> _confirmDelete(BuildContext context, String packageName) async {
    final t = T.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final dt = T.of(dialogCtx);
        return AlertDialog(
          title: Text(dt.marketDeleteConfirmTitle),
          content: Text(
            T.fmt(dt.marketDeleteConfirmContent, {'package': packageName}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: Text(dt.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: Text(dt.delete),
            ),
          ],
        );
      },
    );

    if (confirmed == true && context.mounted) {
      // 用上面已经抓到的 t（避免在 await 后跨 context 取）
      await _deletePackage(context, packageName, t);
    }
  }

  Future<void> _deletePackage(
    BuildContext context,
    String packageName,
    FrameworkStrings t,
  ) async {
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
                Text(t.marketDeleting),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final token = AuthService.token;
      if (token == null) throw Exception(t.errorNotLoggedIn);

      final resp = await http
          .delete(
            Uri.parse('${AppConfig.registryUrl}/package/$packageName'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));

      if (context.mounted) Navigator.pop(context); // 关闭加载对话框

      if (resp.statusCode == 200) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(t.marketDeleteSuccess)));
          // 刷新列表
          _fetchApps();
        }
      } else {
        final data = json.decode(resp.body);
        throw Exception(data['error'] ?? t.marketDeleteFailed);
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // 关闭加载对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(T.fmt(t.marketDeleteFailedWith, {'msg': '$e'})),
          ),
        );
      }
    }
  }

  Widget _buildAppCard(
    BuildContext context,
    Map<String, dynamic> app,
    ColorScheme cs,
  ) {
    final name = app['name'] as String? ?? '';
    final displayName = resolveDisplayName(app, fallback: name);
    final desc = app['description'] as String? ?? '';
    final version = app['version']?.toString() ?? '';
    final author = app['author'] as String? ?? '';

    // 判断当前用户是否是管理员
    final isAdmin = AuthService.currentUser?['role'] == 'admin';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          // 先进详情页；详情页"运行"会 pop 返回带 version 的 app map。
          final result = await Navigator.of(context).push<Object?>(
            MaterialPageRoute(builder: (_) => MarketAppDetailPage(app: app)),
          );
          if (result is Map && context.mounted) {
            Navigator.of(context).pop();
            await widget.onSelect(Map<String, dynamic>.from(result));
          } else if (result == 'run' && context.mounted) {
            // 兼容旧详情页返回值。
            Navigator.of(context).pop();
            await widget.onSelect(app);
          } else if (_selectedTabIndex == 2 && mounted) {
            // 收藏 tab：返回时刷新（详情页里可能取消了收藏）
            _fetchApps();
          }
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
                            displayName,
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
                        T.fmt(T.of(context).marketAuthor, {'author': author}),
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
                  tooltip: T.of(context).marketUnpublishTooltip,
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

// 检测子树里是否存在必须吃满有界高度的 widget（非 shrinkWrap list/grid、
// refresh、顶层/纵向 flex 等）。命中时屏幕级别要走 Column 而不是
// SingleChildScrollView，否则 Expanded/ListView 在 unbounded 高度里会抛
// RenderFlex 异常。
//
// 注意：横向 Row 里的 expanded/flexible 是正常的两列/左右布局写法，不应该让
// 整个长页面失去外层滚动。这里会跟踪父级 flex 方向，只把纵向 flex 视为需要
// 有界高度。
bool _containsListInChildren(
  List<dynamic> children, {
  String parentLayout = 'column',
}) {
  for (final child in children) {
    if (child is Map<String, dynamic>) {
      if (_needsBoundedVerticalParent(child, parentLayout: parentLayout)) {
        return true;
      }
    }
  }
  return false;
}

bool _needsBoundedVerticalParent(
  Map<String, dynamic> child, {
  required String parentLayout,
}) {
  final type = child['type'];
  if (type == 'list' && child['shrinkWrap'] != true) return true;
  if (type == 'cupertino_refresh_list' && child['shrinkWrap'] != true) {
    return true;
  }
  if (type == 'reorderable_list') return true;
  if (type == 'grid' && child['shrinkWrap'] != true) return true;
  if (type == 'refresh') return true;
  // flame_game 跟 list 一样想吃无限高度（Flame GameWidget 占满父级），
  // 没显式给 height 时屏幕级要走 Column 而不是 SingleChildScrollView。
  if (type == 'flame_game' && child['height'] == null) return true;
  // ref 引用的模板里可能塞 list/refresh/expanded（典型：launcher 组件库），
  // 这边解析阶段没法看进 dep 模板，保守按 Column 处理（拿不到滚动条但不崩；
  // 如果 ref 出来是个短小的 leaf，组件作者自己负责裹个 SingleChildScrollView）。
  if (type == 'ref') return true;

  final position = child['position'];
  final isFlexPosition =
      position is Map<String, dynamic> && position['type'] == 'flex';
  final isFlexNode = type == 'expanded' || type == 'flexible' || isFlexPosition;
  if (isFlexNode && parentLayout != 'row') return true;

  // 递归 children 字段。不同容器的默认 layout 不同：container 默认 row，
  // card/screen 默认 column。判断错会把正常两列卡片页误判成不可滚。
  final subChildren = child['children'] as List<dynamic>?;
  if (subChildren != null &&
      _containsListInChildren(
        subChildren,
        parentLayout: _childrenLayoutForNode(child),
      )) {
    return true;
  }

  // 递归单 child 字段（refresh / padding / align / center / expanded 等）。
  // 单 child wrapper 自身不是 Flex 父级，所以内部 expanded 仍然需要被拦住。
  final singleChild = child['child'];
  if (singleChild is Map<String, dynamic> &&
      _needsBoundedVerticalParent(singleChild, parentLayout: 'box')) {
    return true;
  }

  return false;
}

String _childrenLayoutForNode(Map<String, dynamic> child) {
  final rawLayout = child['layout']?.toString();
  if (rawLayout != null && rawLayout.isNotEmpty) return rawLayout;
  final type = child['type'];
  if (type == 'container') return 'row';
  if (type == 'card') return 'column';
  if (type == 'stack') return 'stack';
  if (type == 'wrap') return 'wrap';
  return 'column';
}

List<dynamic> _screenChildren(Map<String, dynamic> screenConfig) {
  final children = screenConfig['children'];
  if (children is List<dynamic>) return children;

  // Compatibility for AI-generated JSON that uses a Flutter-like
  // screen.body shape. The canonical DSL field remains screen.children.
  final body = screenConfig['body'];
  if (body is List<dynamic>) return body;
  if (body is Map<String, dynamic>) return [body];
  return const [];
}

Map<String, dynamic> _screenContentConfig(Map<String, dynamic> screenConfig) {
  if (screenConfig['children'] is List<dynamic>) return screenConfig;

  final body = screenConfig['body'];
  if (body is Map<String, dynamic> &&
      body['type'] == 'container' &&
      body['children'] is List<dynamic>) {
    final merged = Map<String, dynamic>.from(screenConfig);
    merged['children'] = body['children'];
    if (body.containsKey('layout')) merged['layout'] = body['layout'];
    if (body.containsKey('padding')) merged['padding'] = body['padding'];
    return merged;
  }
  return screenConfig;
}

/// 根据当前 screen ID 渲染对应的 JSON 页面
class JsonScreenView extends ConsumerWidget {
  final String fileName;

  /// 当前 JSON-APP 是被"默认启动 App"直接拉起来的根路由：
  /// AppBar 不要再显示返回按钮（顶层就是这个 app，没地方可退），
  /// JSON-APP 内部 navigate 出来的子 screen 仍然显示返回（看 canNavigateBack）。
  final bool isStartupRoot;

  const JsonScreenView({
    super.key,
    required this.fileName,
    this.isStartupRoot = false,
  });

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
        body: Center(child: Text(T.of(context).pageConfigNotFound)),
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
        isStartupRoot: isStartupRoot,
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
    final contentConfig = _screenContentConfig(screenConfig);
    final children = _screenChildren(contentConfig);
    final hasListWidget = _containsListInChildren(
      children,
      parentLayout: (contentConfig['layout'] ?? 'column').toString(),
    );

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

    // 自定义 appBar（screen.appBar Map 配置时启用）
    final customAppBarConfig = screenConfig['appBar'];
    PreferredSizeWidget? appBar;
    if (customAppBarConfig == false) {
      appBar = null;
    } else if (customAppBarConfig is Map<String, dynamic>) {
      appBar = appbar_helper.buildAppBar(
        context,
        customAppBarConfig,
        interpreter,
      );
    } else {
      // 走 resolveTemplate 让 title 支持 "{{ global.xxx }}" 模板
      // （和自定义 appBar / 普通 text widget 行为一致）
      final rawTitle = screenConfig['title']?.toString() ?? interpreter.appName;
      final titleText = interpreter.resolveTemplate(rawTitle);
      // 默认启动 App 的根 screen：没地方可退，藏掉 leading（leading=null +
      // automaticallyImplyLeading=false 才能让 AppBar 完全释放 leading 槽位，
      // 否则 Navigator 会自动塞 BackButton 进来）。
      // JSON-APP 内部 navigate 出来的子 screen，canNavigateBack=true 时正常显示返回。
      final hideLeading = isStartupRoot && !interpreter.canNavigateBack;
      appBar = AppBar(
        title: Text(titleText),
        centerTitle: true,
        automaticallyImplyLeading: !hideLeading,
        leading: hideLeading
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  // 优先回退到上一屏；历史栈空时退出整个 JSON-APP
                  if (interpreter.canNavigateBack) {
                    interpreter.navigateBack();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
      );
    }

    // 可选 drawer（screen.drawer Map 配置时启用）
    Widget? drawer;
    final drawerConfig = screenConfig['drawer'];
    if (drawerConfig is Map<String, dynamic>) {
      drawer = drawer_helper.buildDrawer(context, drawerConfig, interpreter);
    }

    final footerButtonsConfig = screenConfig['footerButtons'];
    final footerButtons = footerButtonsConfig is List
        ? footerButtonsConfig
              .whereType<Map<String, dynamic>>()
              .map((childJson) => interpreter.buildWidget(context, childJson))
              .toList()
        : null;
    final floatingActionButtonConfig = screenConfig['floatingActionButton'];
    final floatingActionButton =
        floatingActionButtonConfig is Map<String, dynamic>
        ? interpreter.buildWidget(context, floatingActionButtonConfig)
        : null;

    // screen.layout=stack 时，需要全屏 Stack（绝对定位才有参考系），
    // 不能再放进 SingleChildScrollView 里——否则 Stack 高度坍缩到子项最大尺寸
    final isStackLayout = (contentConfig['layout'] ?? 'column') == 'stack';

    final Widget bodyContent;
    if (isStackLayout) {
      bodyContent = buildScreenLayout(screenConfig, childWidgets);
    } else if (hasListWidget) {
      bodyContent = buildScreenLayout(contentConfig, childWidgets);
    } else {
      bodyContent = SingleChildScrollView(
        child: buildScreenLayout(contentConfig, childWidgets),
      );
    }

    final onLoad = screenConfig['onLoad'];
    final screen = PopScope(
      // 拦截系统返回手势（iOS edge swipe / Android 返回键）：
      //   - 内部 JSON 历史栈非空 → 拦下来走 navigateBack
      //   - isStartupRoot → 整个就这个 app，没地方退，也拦下来吃掉
      //   - 都没 → 放行，pop 回 FilePickerPage
      canPop: !interpreter.canNavigateBack && !isStartupRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          // JSON-APP 路由已经 pop，把它推过的 dialog 全清掉，防止飘
          // 到主页面上（系统返回 / 边缘滑动这种路径走的不是 back action）
          interpreter.dismissAllModals();
          return;
        }
        // 拦下的手势：有内部历史就回退，否则吃掉（startup root 兜底）
        if (interpreter.canNavigateBack) {
          interpreter.navigateBack();
        }
      },
      child: Scaffold(
        backgroundColor: bgColor,
        appBar: appBar,
        drawer: drawer,
        persistentFooterButtons: footerButtons,
        floatingActionButton: floatingActionButton,
        body: SafeArea(child: bodyContent),
      ),
    );

    if (onLoad is Map<String, dynamic>) {
      return _JsonScreenOnLoad(
        screenId: interpreter.currentScreenId,
        onLoad: onLoad,
        interpreter: interpreter,
        child: screen,
      );
    }

    return screen;
  }
}

class _JsonScreenOnLoad extends StatefulWidget {
  final String screenId;
  final Map<String, dynamic> onLoad;
  final JsonInterpreter interpreter;
  final Widget child;

  const _JsonScreenOnLoad({
    required this.screenId,
    required this.onLoad,
    required this.interpreter,
    required this.child,
  });

  @override
  State<_JsonScreenOnLoad> createState() => _JsonScreenOnLoadState();
}

class _JsonScreenOnLoadState extends State<_JsonScreenOnLoad> {
  String? _loadedScreenId;

  @override
  void initState() {
    super.initState();
    _scheduleIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _JsonScreenOnLoad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screenId != widget.screenId) {
      _scheduleIfNeeded();
    }
  }

  void _scheduleIfNeeded() {
    if (_loadedScreenId == widget.screenId) return;
    _loadedScreenId = widget.screenId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.interpreter.executeAction(widget.onLoad, context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    final t = T.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          t.crashTitle,
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
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
            Text(
              T.fmt(t.crashSubtitle, {'file': fileName}),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                error,
                style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
              ),
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
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      stackTrace,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final fullText =
                          '${T.fmt(t.crashSubtitle, {'file': fileName})}\n\n$error\n\n$stackTrace';
                      await Clipboard.setData(ClipboardData(text: fullText));
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(t.crashCopied)));
                      }
                    },
                    icon: const Icon(Icons.copy_all),
                    label: Text(t.copy),
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
                      final crashMsg =
                          'JSON-APP 运行崩溃，请分析原因并输出修复后的完整 JSON：\n\n'
                          '## 错误\n$error\n\n'
                          '## 堆栈\n$stackTrace';
                      Navigator.of(context).pop();
                      // 通过 DesignerBall 发起 AI 对话
                      DesignerBall.sendCrashReport?.call(crashMsg);
                    },
                    icon: const Icon(Icons.auto_fix_high),
                    label: Text(t.crashAiFix),
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
                    label: Text(t.back),
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
  final bool isStartupRoot;

  const _TabScreenView({
    required this.screenConfig,
    required this.interpreter,
    required this.screens,
    this.isStartupRoot = false,
  });

  @override
  State<_TabScreenView> createState() => _TabScreenViewState();
}

class _TabScreenViewState extends State<_TabScreenView> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = widget.screenConfig['tabs'] as List<dynamic>;
    // 支持 "{{ }}" 模板（同普通 screen 的 AppBar 行为）
    final rawTitle =
        widget.screenConfig['title']?.toString() ?? widget.interpreter.appName;
    final title = widget.interpreter.resolveTemplate(rawTitle);

    final bgColorStr = widget.screenConfig['backgroundColor'] as String?;
    Color? bgColor;
    if (bgColorStr != null && bgColorStr.startsWith('#')) {
      final hex = bgColorStr.replaceFirst('#', '');
      bgColor = Color(int.parse('FF$hex', radix: 16));
    }

    // 当前 tab 配置
    final currentTab = tabs[_currentIndex] as Map<String, dynamic>;
    final currentTabContent = _screenContentConfig(currentTab);
    final tabChildren = _screenChildren(currentTabContent);
    final tabBgColorStr = currentTab['backgroundColor'] as String?;

    Color? tabBgColor;
    if (tabBgColorStr != null && tabBgColorStr.startsWith('#')) {
      final hex = tabBgColorStr.replaceFirst('#', '');
      tabBgColor = Color(int.parse('FF$hex', radix: 16));
    }

    // 构建当前 tab 的内容
    final hasListWidget = _containsListInChildren(
      tabChildren,
      parentLayout: (currentTabContent['layout'] ?? 'column').toString(),
    );
    final childWidgets = tabChildren
        .whereType<Map<String, dynamic>>()
        .map((childJson) => widget.interpreter.buildWidget(context, childJson))
        .toList();

    final padding =
        (currentTab['padding'] as num?)?.toDouble() ??
        (currentTabContent['padding'] as num?)?.toDouble() ??
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
        // tab.label 走 resolveTemplate，支持 {{ t('xxx') }} / {{ global.xxx }}
        // ——和 button.label / text.value 一致
        final label = widget.interpreter.resolveTemplate(
          tab['label']?.toString() ?? '',
        );
        final iconName = tab['icon']?.toString();
        final iconData = iconName != null
            ? IconRegistry.get(iconName) ?? Icons.circle
            : Icons.circle;
        navItems.add(
          BottomNavigationBarItem(icon: Icon(iconData), label: label),
        );
      }
    }

    final interpreter = widget.interpreter;
    return PopScope(
      // 同 JsonScreenView：startup root 时也吃掉系统返回手势
      canPop: !interpreter.canNavigateBack && !widget.isStartupRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (interpreter.canNavigateBack) {
          interpreter.navigateBack();
        }
      },
      child: Scaffold(
        backgroundColor: tabBgColor ?? bgColor,
        appBar: AppBar(
          title: Text(
            widget.interpreter.resolveTemplate(
              currentTab['title']?.toString() ?? title,
            ),
          ),
          centerTitle: true,
          // 默认启动 App 的根 screen：没地方可退，藏掉 leading
          automaticallyImplyLeading:
              !(widget.isStartupRoot && !interpreter.canNavigateBack),
          leading: (widget.isStartupRoot && !interpreter.canNavigateBack)
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    if (interpreter.canNavigateBack) {
                      interpreter.navigateBack();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
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
      if (!mounted) return;
      _showSnackBar(T.of(context).myAppsPublishSuccess);
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('my_apps');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          t.myAppsTitle,
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),
      body: _apps == null
          ? Center(child: CircularProgressIndicator(color: cs.onSurface))
          : _apps!.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 64,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t.myAppsEmpty,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t.myAppsEmptyHint,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
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
                    final meta = app.config['meta'] as Map<String, dynamic>?;
                    final displayName = resolveDisplayName(
                      meta,
                      fallback: app.name,
                    );

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.surfaceContainerHighest,
                          child: Icon(Icons.apps, color: cs.onSurface),
                        ),
                        title: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          app.description.isNotEmpty
                              ? app.description
                              : timeStr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isAdmin)
                              IconButton(
                                icon: Icon(
                                  Icons.cloud_upload_outlined,
                                  size: 20,
                                  color: cs.onSurfaceVariant,
                                ),
                                tooltip: t.myAppsUploadTooltip,
                                onPressed: _uploading
                                    ? null
                                    : () => _uploadToMarket(app),
                              ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: cs.onSurfaceVariant,
                              ),
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
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(t.myAppsUploading),
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
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(s);
}

class _PublishDialog extends StatefulWidget {
  final Map<String, dynamic> config;
  const _PublishDialog({required this.config});

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  // getter 而非 final，确保环境切换后能拿到新 URL（虽然切环境会强制登出
  // 把这个 dialog 也销毁，但写法上更稳）
  String get _registryUrl => AppConfig.registryUrl;

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
    _appidCtrl = TextEditingController(
      text: _isValidUuid(rawAppid) ? rawAppid : '',
    );
    _descCtrl = TextEditingController(
      text: meta['description']?.toString() ?? '',
    );
    _versionCtrl = TextEditingController(
      text: meta['version']?.toString() ?? '1.0.0',
    );
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
      final resp = await http
          .get(
            Uri.parse('$_registryUrl/my-namespaces'),
            headers: {'Authorization': 'Bearer ${AuthService.token}'},
          )
          .timeout(const Duration(seconds: 10));
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
    final t = T.of(context);
    final ctrl = TextEditingController();
    final nsName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final dt = T.of(ctx);
        return AlertDialog(
          title: Text(dt.publishCreateNamespaceTitle),
          content: TextField(
            controller: ctrl,
            decoration: InputDecoration(
              labelText: dt.publishNamespaceName,
              hintText: dt.publishNamespaceHint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(dt.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(dt.create),
            ),
          ],
        );
      },
    );
    if (nsName == null || nsName.isEmpty) return;

    try {
      final resp = await http
          .post(
            Uri.parse('$_registryUrl/namespace/create'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${AuthService.token}',
            },
            body: json.encode({'namespace': nsName}),
          )
          .timeout(const Duration(seconds: 10));

      final data = json.decode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200) {
        await _fetchNamespaces();
        if (mounted) setState(() => _selectedNamespace = nsName);
      } else {
        if (mounted) {
          setState(
            () => _error = data['error']?.toString() ?? t.publishCreateFailed,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = T.fmt(t.errorNetworkWith, {'msg': '$e'}));
      }
    }
  }

  Future<void> _inviteMember() async {
    showDialog(
      context: context,
      builder: (ctx) {
        final dt = T.of(ctx);
        return AlertDialog(
          title: Text(dt.publishInviteMember),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.construction, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                dt.featureInDevelopment,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                dt.featureStayTuned,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(dt.gotIt),
            ),
          ],
        );
      },
    );
  }

  Future<void> _doPublish() async {
    final t = T.of(context);
    // 前端校验
    final name = _nameCtrl.text.trim();
    final appid = _appidCtrl.text.trim();
    final version = _versionCtrl.text.trim();
    final desc = _descCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _error = t.publishPkgNameRequired);
      return;
    }
    if (!_isValidUuid(appid)) {
      setState(() => _error = t.publishAppidInvalid);
      return;
    }
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      setState(() => _error = t.publishVersionInvalid);
      return;
    }
    if (!_isAdmin &&
        (_selectedNamespace == null || _selectedNamespace!.isEmpty)) {
      setState(() => _error = t.publishNamespaceRequired);
      return;
    }

    setState(() {
      _publishing = true;
      _error = null;
    });

    try {
      final resp = await http
          .post(
            Uri.parse('$_registryUrl/publish'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${AuthService.token}',
            },
            body: json.encode({
              'json_content': widget.config,
              'namespace':
                  _isAdmin &&
                      (_selectedNamespace == null ||
                          _selectedNamespace == '_official_')
                  ? ''
                  : _selectedNamespace ?? '',
              'name': name,
              'appid': appid,
              'version': version,
              'description': desc,
              'type': _type,
            }),
          )
          .timeout(const Duration(seconds: 30));

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
            builder: (ctx) {
              final dt = T.of(ctx);
              return AlertDialog(
                title: Text(dt.publishUuidConflictTitle),
                content: Text(
                  T.fmt(dt.publishUuidConflictContent, {'pkg': pkg}),
                ),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(dt.gotIt),
                  ),
                ],
              );
            },
          );
          setState(() => _publishing = false);
        }
        return;
      }

      // 其他错误
      if (mounted) {
        setState(() {
          _error =
              data['error']?.toString() ??
              T.fmt(t.publishFailedWithCode, {'code': resp.statusCode});
          _publishing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = T.fmt(t.errorNetworkWith, {'msg': '$e'});
          _publishing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.publishDialogTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: _inviteMember,
                icon: const Icon(Icons.person_add, size: 18),
                label: Text(
                  t.publishInviteMember,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _createNamespace,
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  t.publishCreateNamespace,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
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
                  child: Text(
                    _error!,
                    style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 命名空间 + 名字（一行两列）
              Row(
                children: [
                  // 命名空间选择器
                  Expanded(
                    child: _loadingNs
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : DropdownButtonFormField<String>(
                            value: _selectedNamespace,
                            decoration: InputDecoration(
                              labelText: t.publishNamespaceField,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 14,
                              ),
                            ),
                            isExpanded: true,
                            items: [
                              if (_isAdmin)
                                DropdownMenuItem(
                                  value: '_official_',
                                  child: Text(
                                    t.publishOfficialNamespace,
                                    style: const TextStyle(
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ),
                              ...(_namespaces ?? []).map((ns) {
                                final n = ns['name'] as String;
                                return DropdownMenuItem(
                                  value: n,
                                  child: Text(n),
                                );
                              }),
                            ],
                            onChanged: (v) =>
                                setState(() => _selectedNamespace = v),
                          ),
                  ),
                  const SizedBox(width: 12),
                  // 包名
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      decoration: InputDecoration(
                        labelText: t.publishPkgNameField,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
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
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                      ),
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() => _appidCtrl.text = _generateUuidV4());
                    },
                    icon: const Icon(Icons.casino, size: 18),
                    label: Text(t.publishRandomGenerate),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
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
                  labelText: t.publishDescField,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
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
                        labelText: t.publishVersionField,
                        hintText: '1.0.0',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _type,
                      decoration: InputDecoration(
                        labelText: t.publishTypeField,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'app', child: Text('App')),
                        DropdownMenuItem(
                          value: 'library',
                          child: Text('Library'),
                        ),
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
          onPressed: _publishing
              ? null
              : () => Navigator.of(context).pop(false),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: _publishing ? null : _doPublish,
          child: _publishing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(t.publishButton),
        ),
      ],
    );
  }
}
