import 'package:local_auth/local_auth.dart';

/// 弹系统生物识别（允许 fallback 到 PIN / 密码）。通过返回 true，失败 / 不支持返回 false。
Future<bool> biometricAuthenticate(String reason) async {
  try {
    final auth = LocalAuthentication();
    final canCheck =
        await auth.canCheckBiometrics || await auth.isDeviceSupported();
    if (!canCheck) return false;
    return await auth.authenticate(
      localizedReason: reason,
      options: const AuthenticationOptions(
        biometricOnly: false, // 允许 fallback 到 PIN / 密码
        stickyAuth: true,
      ),
    );
  } catch (_) {
    return false;
  }
}
