import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
    final fileName = '${ts}_${name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '_')}.json';

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
