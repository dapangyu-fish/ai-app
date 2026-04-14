// JSON Low-Code DSL v3.2 - 主入口
// 使用 Material 3 设计风格，集成 Riverpod 状态管理
// 启动页为文件选择器，选择 JSON 文件后加载渲染 Server-Driven UI
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'json_ui/interpreter.dart';
import 'json_ui/widgets/screen_layout.dart';

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

void main() {
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
      home: const FilePickerPage(),
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

      // 重新创建解释器（清除之前的状态）
      final interpreter = ref.read(interpreterProvider);
      interpreter.loadConfig(config);
      interpreter.executeSteps();

      _loadedFileName = result.files.single.name;

      setState(() => _loading = false);

      if (!mounted) return;

      // 跳转到 JSON 渲染页面
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
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

              // 选择文件按钮
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
                label: Text(_loading ? '加载中...' : '选择 JSON 文件'),
                style: FilledButton.styleFrom(
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

    // 设置导航回调（通过 notifyListeners 触发 rebuild）
    interpreter.onNavigate = (_) {};

    // 检查页面中是否包含 list 类型控件（需要特殊布局处理）
    final children = screenConfig['children'] as List<dynamic>? ?? [];
    final hasListWidget = _containsListWidget(children);

    // 构建子控件列表
    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((childJson) => interpreter.buildWidget(context, childJson))
        .toList();

    // 构建页面布局
    final layoutWidget = buildScreenLayout(screenConfig, childWidgets);

    return Scaffold(
      appBar: AppBar(
        title: Text(screenConfig['title'] ?? interpreter.appName),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // 如果是首屏，返回文件选择页；否则导航到首屏
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
        // 如果页面包含 list 控件，不用 SingleChildScrollView（因为 list 自己可滚动）
        // 否则用 SingleChildScrollView 支持内容溢出滚动
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

  /// 递归检查 children 中是否存在 list 类型控件
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
