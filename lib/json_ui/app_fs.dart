// 应用文档目录文件读写的跨平台门面（facade）。
//
// 编译期通过条件导入选择实现：
//   - 默认（web / wasm）→ app_fs_web.dart，所有操作优雅降级（无文件系统）
//   - dart.library.io 为真（Android / iOS / 桌面）→ app_fs_io.dart，真实 dart:io 实现
//
// 这样 interpreter 不再直接 import 'dart:io' / path_provider，web 才能编译通过。
// 接口只暴露纯类型（String / bytes / List<String>），不泄漏 dart:io 的 File/Directory。
export 'app_fs_web.dart' if (dart.library.io) 'app_fs_io.dart';
