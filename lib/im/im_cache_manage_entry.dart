// IMCacheManagePage 的跨平台入口。条件导入：
//   默认（web）→ im_cache_manage_page_web.dart（占位，IM 不可用）
//   dart.library.io（移动 / 桌面）→ im_cache_manage_page.dart（真实页面，含 OpenIM）
//
// settings_page 通过这个入口引用，避免 web 编译时把 flutter_openim_sdk 拉进来。
export 'im_cache_manage_page_web.dart'
    if (dart.library.io) 'im_cache_manage_page.dart';
