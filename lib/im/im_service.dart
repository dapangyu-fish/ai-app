// IMService 跨平台门面。条件导入：
//   默认（web）→ im_service_web.dart（OpenIM 无 web SDK，全部 no-op 的 stub）
//   dart.library.io（移动 / 桌面）→ im_service_io.dart（真实 flutter_openim_sdk 封装）
//
// 这样 web 编译时不会把 flutter_openim_sdk 拉进产物。IM 聊天 UI 子树在 web 上
// 由调用方（main / settings_page）通过条件导入剪枝，不会被编译。
export 'im_service_web.dart' if (dart.library.io) 'im_service_io.dart';
