import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 当前页面作用域
/// - framework: Flutter 框架页面（登录、设置、市场、我的APP、崩溃页等）
/// - jsonApp: 正在运行某个 JSON-APP 的页面
/// - unknown: 尚未确定

enum AppPageScope {
  unknown,
  framework,
  jsonApp,
}

/// 全局页面状态
///
/// 用于回答类似：
/// - 当前是不是在 JSON-APP 里？
/// - 当前框架页是什么？
/// - 当前 JSON-APP 的 screenId 是什么？
/// - 当前 JSON-APP 名称是什么？
class CurrentPageState extends ChangeNotifier {
  static CurrentPageState? _instance;
  static CurrentPageState get instance => _instance ??= CurrentPageState._();
  CurrentPageState._();

  AppPageScope _scope = AppPageScope.unknown;
  String? _frameworkPage;
  String? _jsonScreenId;
  String? _jsonAppName;

  AppPageScope get scope => _scope;
  String? get frameworkPage => _frameworkPage;
  String? get jsonScreenId => _jsonScreenId;
  String? get jsonAppName => _jsonAppName;

  bool get isInJsonApp => _scope == AppPageScope.jsonApp;
  bool get isInFrameworkPage => _scope == AppPageScope.framework;

  void setFrameworkPage(String pageName) {
    final changed =
        _scope != AppPageScope.framework ||
        _frameworkPage != pageName ||
        _jsonScreenId != null ||
        _jsonAppName != null;
    _scope = AppPageScope.framework;
    _frameworkPage = pageName;
    _jsonScreenId = null;
    _jsonAppName = null;
    if (changed) {
      debugPrint('[CurrentPageState] framework -> $pageName');
      notifyListeners();
    }
  }

  void setJsonAppPage({required String screenId, required String appName}) {
    final changed =
        _scope != AppPageScope.jsonApp ||
        _jsonScreenId != screenId ||
        _jsonAppName != appName ||
        _frameworkPage != null;
    _scope = AppPageScope.jsonApp;
    _frameworkPage = null;
    _jsonScreenId = screenId;
    _jsonAppName = appName;
    if (changed) {
      debugPrint('[CurrentPageState] jsonApp -> app=$appName, screen=$screenId');
      notifyListeners();
    }
  }

  Map<String, dynamic> snapshot() {
    return {
      'scope': _scope.name,
      'frameworkPage': _frameworkPage,
      'jsonScreenId': _jsonScreenId,
      'jsonAppName': _jsonAppName,
      'isInJsonApp': isInJsonApp,
    };
  }
}

/// 本地 JSON-APP 存储 — 保存 AI 生成的 APP 到本地文件系统
class AppStorage {
  static AppStorage? _instance;
  static AppStorage get instance => _instance ??= AppStorage._();
  AppStorage._();

  Future<String> get _dirPath async {
    final dir = await getApplicationDocumentsDirectory();
    final appDir = Directory('${dir.path}/my_apps');
    if (!appDir.existsSync()) appDir.createSync(recursive: true);
    return appDir.path;
  }

  /// 保存 JSON-APP，返回文件名
  Future<String> save(Map<String, dynamic> jsonConfig) async {
    final dir = await _dirPath;
    final meta = jsonConfig['meta'] as Map<String, dynamic>? ?? {};
    final name = (meta['name'] as String?) ?? 'Untitled';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fileName = '${ts}_${name.replaceAll(RegExp(r'[^\w一-鿿]'), '_')}.json';

    // 在 JSON 中嵌入保存时间
    jsonConfig['_saved_at'] = DateTime.now().toIso8601String();

    final file = File('$dir/$fileName');
    await file.writeAsString(json.encode(jsonConfig));
    return fileName;
  }

  /// 列出所有已保存的 APP（按时间倒序）
  Future<List<SavedApp>> list() async {
    final dir = await _dirPath;
    final d = Directory(dir);
    if (!d.existsSync()) return [];

    final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    files.sort((a, b) => b.path.compareTo(a.path)); // 按文件名倒序（时间戳前缀）

    final result = <SavedApp>[];
    for (final file in files) {
      try {
        final content = await file.readAsString();
        final data = json.decode(content) as Map<String, dynamic>;
        final meta = data['meta'] as Map<String, dynamic>? ?? {};
        result.add(SavedApp(
          fileName: file.uri.pathSegments.last,
          name: (meta['name'] as String?) ?? 'Untitled',
          description: (meta['description'] as String?) ?? '',
          savedAt: data['_saved_at'] as String? ?? '',
          config: data,
        ));
      } catch (_) {}
    }
    return result;
  }

  /// 读取单个 APP
  Future<Map<String, dynamic>?> load(String fileName) async {
    final dir = await _dirPath;
    final file = File('$dir/$fileName');
    if (!file.existsSync()) return null;
    final content = await file.readAsString();
    return json.decode(content) as Map<String, dynamic>;
  }

  /// 删除 APP
  Future<void> delete(String fileName) async {
    final dir = await _dirPath;
    final file = File('$dir/$fileName');
    if (file.existsSync()) await file.delete();
  }
}

class SavedApp {
  final String fileName;
  final String name;
  final String description;
  final String savedAt;
  final Map<String, dynamic> config;

  SavedApp({
    required this.fileName,
    required this.name,
    required this.description,
    required this.savedAt,
    required this.config,
  });
}
