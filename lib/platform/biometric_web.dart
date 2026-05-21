// Web 无生物识别，恒返回 false。JSON-APP 应在 web 上回退到密码等其它校验方式。
Future<bool> biometricAuthenticate(String reason) async => false;
