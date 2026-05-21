// 通用文件系统门面（绝对路径 + 目录定位）。条件导入：
//   默认（web）→ native_fs_web.dart（全部 no-op，返回 null/false/空）
//   dart.library.io（移动 / 桌面）→ native_fs_io.dart（真实 dart:io + path_provider）
//
// 用途：cache_manager / app_storage / launcher_bridges / local_data_wiper 等
// 需要落盘的模块。web 上这些操作本就无意义，统一优雅降级。
export 'native_fs_web.dart' if (dart.library.io) 'native_fs_io.dart';
