import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 原生平台实现：所有相对路径都基于应用文档目录。
class AppFs {
  static Directory? _docDir;

  static Future<Directory> _dir() async {
    _docDir ??= await getApplicationDocumentsDirectory();
    return _docDir!;
  }

  /// 写字符串（自动创建父目录）。成功返回 true。
  static Future<bool> writeString(String relPath, String content) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/$relPath');
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 读字符串。文件不存在或出错返回 null。
  static Future<String?> readString(String relPath) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/$relPath');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> exists(String relPath) async {
    try {
      final dir = await _dir();
      return await File('${dir.path}/$relPath').exists();
    } catch (_) {
      return false;
    }
  }

  /// 删除文件。存在并删除成功返回 true，不存在或出错返回 false。
  static Future<bool> deleteFile(String relPath) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/$relPath');
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 列出目录下的文件名（只含文件，不含子目录）。
  static Future<List<String>> listFiles(String relDir) async {
    try {
      final dir = await _dir();
      final target = Directory('${dir.path}/$relDir');
      if (!await target.exists()) return <String>[];
      final entities = await target.list().toList();
      return entities
          .whereType<File>()
          .map((f) => f.path.split('/').last)
          .toList();
    } catch (_) {
      return <String>[];
    }
  }

  /// 读取**绝对路径**文件并 base64 编码（@file_to_base64 用，路径来自 image_picker 等）。
  static Future<String?> readAbsoluteAsBase64(String absPath) async {
    try {
      final file = File(absPath);
      if (!await file.exists()) return null;
      return base64Encode(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }
}
