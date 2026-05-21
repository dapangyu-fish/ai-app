// Web 平台实现：浏览器无文件系统，所有操作优雅降级（不抛异常，返回空/失败）。
//
// 影响：依赖 @file_* 持久化的 JSON-APP 在 web 上不会崩溃，但数据不落盘
// （读永远返回空 / 写永远失败）。如未来需要 web 持久化，可在此用
// IndexedDB / SharedPreferences 重写这些方法即可，调用方无需改动。
class AppFs {
  static Future<bool> writeString(String relPath, String content) async => false;
  static Future<String?> readString(String relPath) async => null;
  static Future<bool> exists(String relPath) async => false;
  static Future<bool> deleteFile(String relPath) async => false;
  static Future<List<String>> listFiles(String relDir) async => const <String>[];
  static Future<String?> readAbsoluteAsBase64(String absPath) async => null;
}
