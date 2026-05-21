import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/native_fs.dart';

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

  /// my_apps 目录绝对路径；web 上无文件系统返回 null。
  Future<String?> get _dirPath async {
    final docPath = await NativeFs.appDocDir();
    if (docPath == null) return null;
    final appDir = '$docPath/my_apps';
    await NativeFs.ensureDir(appDir);
    return appDir;
  }

  /// 保存 JSON-APP，返回文件名
  Future<String> save(Map<String, dynamic> jsonConfig) async {
    final meta = jsonConfig['meta'] as Map<String, dynamic>? ?? {};
    final name = (meta['name'] as String?) ?? 'Untitled';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fileName = '${ts}_${name.replaceAll(RegExp(r'[^\w一-鿿]'), '_')}.json';

    // 在 JSON 中嵌入保存时间
    jsonConfig['_saved_at'] = DateTime.now().toIso8601String();

    final dir = await _dirPath;
    if (dir == null) return fileName; // web：不落盘，仅返回名字
    await NativeFs.writeStringAbs('$dir/$fileName', json.encode(jsonConfig));
    return fileName;
  }

  /// 列出所有已保存的 APP（按时间倒序）
  Future<List<SavedApp>> list() async {
    final dir = await _dirPath;
    if (dir == null) return [];

    final paths = await NativeFs.listFilesAbs(dir);
    final jsonPaths = paths.where((p) => p.endsWith('.json')).toList()
      ..sort((a, b) => b.compareTo(a)); // 按文件名倒序（时间戳前缀）

    final result = <SavedApp>[];
    for (final p in jsonPaths) {
      try {
        final content = await NativeFs.readStringAbs(p);
        if (content == null) continue;
        final data = json.decode(content) as Map<String, dynamic>;
        final meta = data['meta'] as Map<String, dynamic>? ?? {};
        result.add(SavedApp(
          fileName: p.split('/').last,
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
    if (dir == null) return null;
    final content = await NativeFs.readStringAbs('$dir/$fileName');
    if (content == null) return null;
    return json.decode(content) as Map<String, dynamic>;
  }

  /// 删除 APP
  Future<void> delete(String fileName) async {
    final dir = await _dirPath;
    if (dir == null) return;
    await NativeFs.deleteAbs('$dir/$fileName');
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
