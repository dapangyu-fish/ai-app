import 'dart:typed_data';

// Web 实现：浏览器无文件系统，所有操作优雅降级。
class NativeFs {
  static Future<String?> appDocDir() async => null;
  static Future<String?> appSupportDir() async => null;
  static Future<String?> tempDir() async => null;
  static Future<void> ensureDir(String absPath) async {}
  static Future<bool> existsAbs(String absPath) async => false;
  static Future<String?> readStringAbs(String absPath) async => null;
  static Future<Uint8List?> readBytesAbs(String absPath) async => null;
  static Future<bool> writeStringAbs(String absPath, String content) async =>
      false;
  static Future<bool> writeBytesAbs(String absPath, List<int> bytes) async =>
      false;
  static Future<bool> deleteAbs(String absPath) async => false;
  static Future<bool> deleteDirAbs(String absPath) async => false;
  static Future<List<String>> listFilesAbs(String absDir) async =>
      const <String>[];
}
