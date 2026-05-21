// 本地文件媒体（图片 / 视频）的跨平台门面。条件导入：
//   默认（web）→ local_media_web.dart（抛 UnsupportedError，仅为编译占位）
//   dart.library.io（移动 / 桌面）→ local_media_io.dart（dart:io File 实现）
//
// 注意：调用方都在 `if (!kIsWeb)` 分支里调这些函数，web 上不会真正执行到，
// 所以 web 实现抛异常是安全的——纯粹为了让 web 编译时不依赖 dart:io File。
export 'local_media_web.dart' if (dart.library.io) 'local_media_io.dart';
