// 生物识别（指纹 / 人脸）的跨平台门面。条件导入：
//   默认（web）→ biometric_web.dart（恒返回 false，web 无生物识别）
//   dart.library.io（移动 / 桌面）→ biometric_io.dart（local_auth 实现）
//
// 用条件导入而非 kIsWeb 守卫，是为了 web 编译时彻底不依赖 local_auth。
export 'biometric_web.dart' if (dart.library.io) 'biometric_io.dart';
