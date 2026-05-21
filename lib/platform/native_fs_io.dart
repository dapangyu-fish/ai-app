import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 原生实现：直接走 dart:io + path_provider。
class NativeFs {
  static Future<String?> appDocDir() async {
    try {
      return (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> appSupportDir() async {
    try {
      return (await getApplicationSupportDirectory()).path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> tempDir() async {
    try {
      return (await getTemporaryDirectory()).path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> ensureDir(String absPath) async {
    try {
      final d = Directory(absPath);
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (_) {}
  }

  static Future<bool> existsAbs(String absPath) async {
    try {
      return File(absPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<String?> readStringAbs(String absPath) async {
    try {
      final f = File(absPath);
      if (!f.existsSync()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 写字符串（自动创建父目录）。成功返回 true。
  static Future<bool> writeStringAbs(String absPath, String content) async {
    try {
      final f = File(absPath);
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      await f.writeAsString(content);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteAbs(String absPath) async {
    try {
      final f = File(absPath);
      if (f.existsSync()) {
        await f.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteDirAbs(String absPath) async {
    try {
      final d = Directory(absPath);
      if (await d.exists()) {
        await d.delete(recursive: true);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 列出目录下的文件**绝对路径**（不含子目录）。
  static Future<List<String>> listFilesAbs(String absDir) async {
    try {
      final d = Directory(absDir);
      if (!d.existsSync()) return <String>[];
      return d.listSync().whereType<File>().map((f) => f.path).toList();
    } catch (_) {
      return <String>[];
    }
  }
}
